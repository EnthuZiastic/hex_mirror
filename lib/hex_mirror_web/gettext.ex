defmodule HexMirrorWeb.Gettext do
  @moduledoc """
  Gettext backend for `:hex_mirror`.
  """

  use Gettext.Backend, otp_app: :hex_mirror
end
