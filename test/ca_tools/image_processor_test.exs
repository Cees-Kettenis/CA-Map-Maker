defmodule CATools.ImageProcessorTest do
  use ExUnit.Case, async: true
  alias CATools.Maps.ImageProcessor
  alias Vix.Vips.{Image, Operation}

  test "wide and tall images shrink proportionally and small images are not enlarged" do
    for {width, height, expected_width, expected_height} <- [
          {1000, 600, 500, 300},
          {600, 1000, 300, 500},
          {80, 160, 80, 160}
        ] do
      {:ok, image} = Operation.black(width, height, bands: 3)
      {:ok, input} = Image.write_to_buffer(image, ".png")
      assert {:ok, output} = ImageProcessor.process(input)
      assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = output
      assert byte_size(output) <= 100_000
      assert {:ok, decoded} = Image.new_from_buffer(output)
      assert Image.width(decoded) == expected_width
      assert Image.height(decoded) == expected_height
    end
  end

  test "detailed images reduce encoder quality only when needed to fit 100 KB" do
    {:ok, image} =
      Image.new_from_binary(
        :crypto.strong_rand_bytes(500 * 500 * 3),
        500,
        500,
        3,
        :VIPS_FORMAT_UCHAR
      )

    {:ok, large} = Image.write_to_buffer(image, ".webp", Q: 80, effort: 4, strip: true)
    assert byte_size(large) > 100_000
    {:ok, png} = Image.write_to_buffer(image, ".png")
    assert {:ok, output} = ImageProcessor.process(png)
    assert byte_size(output) <= 100_000
    assert {:ok, decoded} = Image.new_from_buffer(output)
    assert Image.width(decoded) == 500
    assert Image.height(decoded) == 500
  end

  test "invalid raster data and inputs exceeding 5 MB are rejected" do
    assert {:error, _} = ImageProcessor.process(<<137, 80, 78, 71, 13, 10, 26, 10, 0>>)
    assert {:error, :image_too_large} = ImageProcessor.process(:binary.copy("x", 5_000_001))
  end
end
