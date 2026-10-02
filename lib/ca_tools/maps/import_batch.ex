defmodule CATools.Maps.ImportBatch do
  @moduledoc "Tracks the progress and cancellation of a Campfire import."
  use Ecto.Schema

  @type t :: %__MODULE__{}
  schema "import_batches" do
    field :status, Ecto.Enum,
      values: [:queued, :processing, :completed, :completed_with_errors, :cancelled],
      default: :queued

    field :total_count, :integer, default: 0
    field :processed_count, :integer, default: 0
    field :success_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    belongs_to :user, CATools.Accounts.User
    belongs_to :map, CATools.Maps.UserMap
    timestamps(type: :utc_datetime)
  end
end
