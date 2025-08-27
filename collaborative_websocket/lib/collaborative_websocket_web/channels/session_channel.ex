defmodule CollaborativeWebsocketWeb.SessionChannel do
  use CollaborativeWebsocketWeb, :channel
  
  alias CollaborativeWebsocket.SessionState
  
  @impl true
  def join("session:room", %{"user_id" => user_id, "last_known_version" => last_known_version}, socket) do
    # Store user info in socket
    socket = assign(socket, :user_id, user_id)
    socket = assign(socket, :last_known_version, last_known_version)
    
    # Add user to session
    SessionState.add_user(user_id, self())
    
    # Send synchronization data
    send(self(), :sync_user)
    
    {:ok, socket}
  end
  
  @impl true
  def join("session:room", %{"user_id" => user_id}, socket) do
    # Handle case where last_known_version is not provided
    join("session:room", %{"user_id" => user_id, "last_known_version" => nil}, socket)
  end
  
  @impl true
  def handle_info(:sync_user, socket) do
    user_id = socket.assigns.user_id
    last_known_version = socket.assigns.last_known_version
    
    # Send sync start
    sync_id = generate_sync_id()
    push(socket, "sync_start", %{sync_id: sync_id})
    
    # Get events since last known version
    events = SessionState.get_events_since(last_known_version)
    
    # Send snapshot if there are events
    unless Enum.empty?(events) do
      push(socket, "snapshot", %{events: events})
      
      # Simulate processing delay to demonstrate race condition
      Process.sleep(100)
    end
    
    # Send sync complete
    current_version = SessionState.get_current_version()
    push(socket, "sync_complete", %{current_version: current_version})
    
    # Notify other users that someone joined
    broadcast_from(socket, "user_joined", %{user_id: user_id})
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_in("draw", payload, socket) do
    user_id = socket.assigns.user_id
    event = create_event(user_id, "draw", payload)
    
    # Add event to session state
    SessionState.add_event(event)
    
    # Broadcast to all users in the session
    broadcast(socket, "event", %{event: event})
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_in("circle", payload, socket) do
    user_id = socket.assigns.user_id
    event = create_event(user_id, "circle", payload)
    
    # Add event to session state
    SessionState.add_event(event)
    
    # Broadcast to all users in the session
    broadcast(socket, "event", %{event: event})
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_in("move", payload, socket) do
    user_id = socket.assigns.user_id
    event = create_event(user_id, "move", payload)
    
    # Add event to session state
    SessionState.add_event(event)
    
    # Broadcast to all users in the session
    broadcast(socket, "event", %{event: event})
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_in("delete", payload, socket) do
    user_id = socket.assigns.user_id
    event = create_event(user_id, "delete", payload)
    
    # Add event to session state
    SessionState.add_event(event)
    
    # Broadcast to all users in the session
    broadcast(socket, "event", %{event: event})
    
    {:noreply, socket}
  end
  
  @impl true
  def terminate(_reason, socket) do
    user_id = socket.assigns.user_id
    SessionState.remove_user(user_id)
    
    # Notify other users that someone left
    broadcast_from(socket, "user_left", %{user_id: user_id})
    
    :ok
  end
  
  # Private functions
  
  defp create_event(user_id, event_type, payload) do
    %{
      id: generate_event_id(),
      user_id: user_id,
      timestamp: System.system_time(:millisecond),
      event: Map.put(payload, "type", event_type)
    }
  end
  
  defp generate_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
  
  defp generate_sync_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end