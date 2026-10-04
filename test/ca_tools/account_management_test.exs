defmodule CATools.AccountManagementTest do
  use CATools.DataCase, async: true
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.{Accounts, Communities, Maps, Repo}
  alias CATools.Accounts.{User, UserToken}

  alias CATools.Maps.{
    CachedImage,
    ImageCache,
    ImageUpload,
    ImportBatch,
    MapPoint,
    MapSource,
    UserMap
  }

  use Oban.Testing, repo: Repo

  test "only the administrator creates users; email setup is single-use and cannot grant admin" do
    scope = user_scope_fixture(admin_user_fixture())
    email = unique_user_email()

    assert {:ok, user} =
             Accounts.create_user(
               scope,
               %{email: email, admin: true, password: "ignored password"},
               &"https://example.com/reset/#{&1}"
             )

    refute user.admin
    assert user.hashed_password == nil
    assert user.encrypted_credentials == nil

    assert_receive {:email, %Swoosh.Email{subject: "Set up your Pogo Meetups account"} = mail}

    assert mail.to == [{"", email}]
    assert mail.subject == "Set up your Pogo Meetups account"
    refute mail.text_body =~ "ignored password"
    [_, token] = Regex.run(~r{https://example.com/reset/([^\s]+)}, mail.text_body)
    assert Accounts.get_user_by_password_reset_token(token).id == user.id

    assert {:ok, {updated, _}} =
             Accounts.reset_user_password(token, %{
               password: valid_user_password(),
               password_confirmation: valid_user_password()
             })

    assert Accounts.get_user_by_email_and_password(email, valid_user_password()).id ==
             updated.id

    assert Accounts.get_user_by_password_reset_token(token) == nil

    assert {:error, :forbidden} =
             Accounts.create_user(user_scope_fixture(user), %{email: unique_user_email()}, & &1)

    assert Accounts.list_users(user_scope_fixture(user)) == []
  end

  test "imports share only the admin token and a forged admin struct cannot change it" do
    admin = admin_user_fixture()
    regular = user_fixture()

    assert {:ok, admin} =
             Accounts.update_user_campfire_token(admin, %{campfire_token_input: "shared-token"})

    assert Accounts.shared_campfire_credentials(regular) ==
             Accounts.get_user_campfire_credentials(admin)

    assert Repo.get!(User, regular.id).encrypted_credentials == nil

    assert {:error, _} =
             Accounts.update_user_campfire_token(%{regular | admin: true}, %{
               campfire_token_input: "other-token"
             })

    assert {:error, :forbidden} = Accounts.get_user_campfire_credentials(regular)
    assert {:error, _} = Accounts.delete_user_campfire_token(regular)
  end

  test "deletion cascades all owned data, invitations, jobs and exclusive files, retaining shared images" do
    scope = user_scope_fixture()
    other = user_scope_fixture()
    map = map_fixture(scope)
    other_map = map_fixture(other)

    {:ok, community} =
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/delete-me"
      })

    {:ok, other_community} =
      Communities.save(other, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/keep-me"
      })

    {:ok, _} = Communities.invite(scope, %{email: other.user.email})
    {:ok, _} = Communities.invite(other, %{email: scope.user.email})
    Repo.insert!(%Maps.CommunitySelection{map_id: map.id, community_id: community.id})
    token = Accounts.generate_user_session_token(scope.user)

    urls =
      Enum.map(
        ["exclusive", "shared", "logo"],
        &"https://cdn.example.com/#{&1}-#{scope.user.id}.png"
      )

    [exclusive_url, shared_url, logo_url] = urls
    ids = Enum.map(urls, &ImageCache.key/1)
    [exclusive_id, shared_id, logo_id] = ids
    upload_id = ImageCache.key("upload-#{scope.user.id}")
    File.mkdir_p!(ImageCache.directory())

    for id <- ids ++ [upload_id] do
      Repo.insert!(%CachedImage{
        id: id,
        status: "saved",
        content_type: "image/webp",
        attempted_at: DateTime.utc_now(:second)
      })

      File.write!(Path.join(ImageCache.directory(), id), "cached")
    end

    on_exit(fn ->
      Enum.each(ids ++ [upload_id], &File.rm(Path.join(ImageCache.directory(), &1)))
    end)

    Repo.insert!(%ImageUpload{user_id: scope.user.id, image_id: upload_id})

    for {target_map, cover, avatar} <- [
          {map, exclusive_url, shared_url},
          {other_map, shared_url, nil}
        ] do
      Repo.insert!(%MapPoint{
        map_id: target_map.id,
        map_source_id: hd(target_map.sources).id,
        title: "Meetup",
        latitude: 3.0,
        longitude: 101.0,
        cover_photo_url: cover,
        host_avatar_url: avatar
      })
    end

    Repo.update!(Ecto.Changeset.change(community, avatar_url: logo_url))
    image_job = Oban.insert!(CATools.Campfire.ImageCacheJob.new(%{"url" => exclusive_url}))
    own_map_ids = [map.id, community.map_id]
    own_source_ids = Repo.all(from s in MapSource, where: s.map_id in ^own_map_ids, select: s.id)

    own_batch_ids =
      Repo.all(from b in ImportBatch, where: b.user_id == ^scope.user.id, select: b.id)

    assert {:error, :confirmation_required} = Accounts.delete_account(scope, other.user.email)
    assert Repo.get(User, scope.user.id)
    assert {:ok, tokens} = Accounts.delete_account(scope, scope.user.email)
    assert tokens != []
    assert Repo.get(User, scope.user.id) == nil
    assert Accounts.get_user_by_session_token(token) == nil
    refute Repo.exists?(from t in UserToken, where: t.user_id == ^scope.user.id)
    refute Repo.exists?(from m in UserMap, where: m.id in ^own_map_ids)
    refute Repo.exists?(from s in MapSource, where: s.id in ^own_source_ids)
    refute Repo.exists?(from b in ImportBatch, where: b.id in ^own_batch_ids)
    refute Repo.exists?(from p in MapPoint, where: p.map_id in ^own_map_ids)
    refute Repo.exists?(from c in Communities.Community, where: c.user_id == ^scope.user.id)

    refute Repo.exists?(
             from i in Communities.Invitation,
               where: i.community_id == ^community.id or i.email == ^scope.user.email
           )

    refute Repo.exists?(from c in Maps.CommunitySelection, where: c.map_id in ^own_map_ids)
    refute Repo.exists?(from u in ImageUpload, where: u.user_id == ^scope.user.id)

    assert Repo.query!("SELECT 1 FROM import_windows WHERE user_id = $1", [scope.user.id]).rows ==
             []

    refute Repo.exists?(
             from j in Oban.Job,
               where:
                 fragment("?->>'user_id'", j.args) == ^to_string(scope.user.id) or
                   fragment("?->>'source_id'", j.args) in ^Enum.map(own_source_ids, &to_string/1) or
                   fragment("?->>'community_id'", j.args) == ^to_string(community.id)
           )

    assert Repo.get(Oban.Job, image_job.id) == nil

    for id <- [exclusive_id, logo_id, upload_id] do
      assert Repo.get(CachedImage, id) == nil
      refute File.exists?(Path.join(ImageCache.directory(), id))
    end

    assert Repo.get(CachedImage, shared_id)
    assert File.exists?(Path.join(ImageCache.directory(), shared_id))
    assert Repo.get(User, other.user.id)
    assert Repo.get(UserMap, other_map.id)
    assert Repo.get(Communities.Community, other_community.id)
    # A stale worker or enqueue call cannot resurrect deleted cache data.
    assert :ok = ImageCache.fetch(exclusive_url, require_reference: true)
    assert :ok = ImageCache.enqueue([exclusive_url])
    assert Repo.get(CachedImage, exclusive_id) == nil
    refute_enqueued(worker: CATools.Campfire.ImageCacheJob, args: %{url: exclusive_url})
    assert {:error, :not_found} = Accounts.shared_campfire_credentials(scope.user)
  end

  test "file cleanup errors roll back deletion rather than reporting success" do
    scope = user_scope_fixture()
    id = ImageCache.key("cannot-delete-#{scope.user.id}")
    Repo.insert!(%CachedImage{id: id, status: "saved", attempted_at: DateTime.utc_now(:second)})
    Repo.insert!(%ImageUpload{user_id: scope.user.id, image_id: id})
    path = Path.join(ImageCache.directory(), id)
    File.mkdir_p!(path)
    on_exit(fn -> File.rmdir(path) end)
    assert {:error, {:file_cleanup, _}} = Accounts.delete_account(scope, scope.user.email)
    assert Repo.get!(User, scope.user.id)
    assert Repo.get!(CachedImage, id)
    assert Repo.exists?(from u in ImageUpload, where: u.user_id == ^scope.user.id)
  end

  test "bootstrap enforces a password and a single administrator" do
    email = unique_user_email()
    assert {:error, _} = Accounts.bootstrap_admin(email, "")
    assert {:ok, admin} = Accounts.bootstrap_admin(email, valid_user_password())
    assert admin.admin
    assert admin.confirmed_at
    assert Accounts.get_user_by_email_and_password(email, valid_user_password()).id == admin.id
    assert {:error, _} = Accounts.bootstrap_admin(unique_user_email(), valid_user_password())
    token = Accounts.generate_user_session_token(admin)
    assert {:ok, _admin} = Accounts.bootstrap_admin(email, "new secure password")
    assert Accounts.get_user_by_session_token(token) == nil
  end
end
