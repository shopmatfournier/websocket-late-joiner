defmodule CollaborativeWebsocketWeb.PageController do
  use CollaborativeWebsocketWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
