defmodule CATools.Maps.ImageProcessor do
  @moduledoc "Creates bounded WebP images for uploads and the meetup cache."

  alias Vix.Vips.{Image, Operation}

  @doc "Decodes a raster image, preserves its proportions and returns a WebP within 500 by 500 pixels and 100 KB."
  @spec process(binary()) :: {:ok, binary()} | {:error, term()}
  def process(body) do
    with true <- byte_size(body) > 0 and byte_size(body) <= 5_000_000,
         {:ok, image} <- Image.new_from_buffer(body),
         true <- Image.width(image) * Image.height(image) <= 40_000_000,
         {:ok, thumbnail} <-
           Operation.thumbnail_image(image, 500,
             height: 500,
             size: :VIPS_SIZE_DOWN
           ),
         {:ok, webp} <-
           Enum.reduce_while(
             [90, 85, 80, 70, 60, 50, 40, 30, 20, 10],
             {:error, :processed_image_too_large},
             fn quality, _ ->
               case Image.write_to_buffer(thumbnail, ".webp", Q: quality, effort: 4, strip: true) do
                 {:ok, body} when byte_size(body) <= 100_000 -> {:halt, {:ok, body}}
                 {:ok, _body} -> {:cont, {:error, :processed_image_too_large}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end
           ) do
      {:ok, webp}
    else
      false -> {:error, :image_too_large}
      {:error, reason} -> {:error, reason}
    end
  end
end
