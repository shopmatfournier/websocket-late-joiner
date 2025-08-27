defmodule CollaborativeWebsocketWeb.ReliableSessionChannel do
  @moduledoc """
  Enhanced session channel with reliable event delivery.
  
  Phoenix-specific features used:
  - Channel replies for acknowledgments
  - Phoenix.PubSub for distributed messaging
  - GenServer integration for state management
  - Process monitoring for connection health
  """
  
  use CollaborativeWebsocketWeb, :channel
  
  alias CollaborativeWebsocket.ReliableSessionState
  alias Phoenix.PubSub
  
  require Logger
  
  # Channel callbacks
  
  @impl true
  def join("session:room", %{"user_id" => user_id} = params, socket) do
    # Extract last known sequence if provided
    last_known_sequence = Map.get(params, "last_known_sequence", 0)
    last_known_sequence = case last_known_sequence do
      seq when is_integer(seq) -> seq
      seq when is_binary(seq) -> 
        case Integer.parse(seq) do
          {num, ""} -> num
          _ -> 0
        end
      _ -> 0
    end
    
    # Add user to reliable session state
    ReliableSessionState.add_user(user_id, self(), last_known_sequence)
    
    # Subscribe to PubSub for reliable events
    PubSub.subscribe(CollaborativeWebsocket.PubSub, "session:room")
    
    # Store user info in socket
    socket = socket
    |> assign(:user_id, user_id)
    |> assign(:last_known_sequence, last_known_sequence)
    |> assign(:connection_id, generate_connection_id())
    
    # Schedule synchronization after join
    send(self(), :sync_user)
    
    Logger.info("User #{user_id} joined with sequence #{last_known_sequence}")
    
    {:ok, socket}
  end
  
  # Handle synchronization after join
  @impl true
  def handle_info(:sync_user, socket) do
    user_id = socket.assigns.user_id
    last_known_sequence = socket.assigns.last_known_sequence
    
    # Send sync start with unique ID
    sync_id = generate_sync_id()
    push(socket, "sync_start", %{sync_id: sync_id})
    
    # Get events for catchup
    events = ReliableSessionState.get_events_since(last_known_sequence)
    current_sequence = ReliableSessionState.get_current_sequence()
    
    # Send snapshot if needed
    unless Enum.empty?(events) do
      push(socket, "snapshot", %{
        events: events,
        last_sequence: current_sequence
      })
      
      # Simulate processing delay for demo
      Process.sleep(100)
    end
    
    # Send sync complete
    push(socket, "sync_complete", %{
      current_sequence: current_sequence
    })
    
    # Notify others about join (using PubSub)
    PubSub.broadcast_from(
      CollaborativeWebsocket.PubSub,
      self(),
      "session:room", 
      {:user_joined, user_id}
    )
    
    Logger.info("User #{user_id} synchronized")
    
    {:noreply, socket}
  end
  
  # Handle reliable events from PubSub
  @impl true
  def handle_info({:reliable_event, event, _user_ids}, socket) do
    # Push event with acknowledgment requirement
    ref = push(socket, "event", %{
      event: event,
      ack_required: true,
      ref: generate_event_ref()
    })
    
    # Store reference for timeout handling
    socket = assign(socket, :pending_ack, {ref, event.sequence_number})
    
    {:noreply, socket}
  end
  
  # Handle user joined events
  @impl true  
  def handle_info({:user_joined, user_id}, socket) do
    if socket.assigns.user_id != user_id do
      push(socket, "user_joined", %{user_id: user_id})
    end
    {:noreply, socket}
  end
  
  # Handle user left events
  @impl true
  def handle_info({:user_left, user_id}, socket) do
    if socket.assigns.user_id != user_id do
      push(socket, "user_left", %{user_id: user_id})
    end
    {:noreply, socket}
  end
  
  # Handle user timeout events
  @impl true
  def handle_info({:user_timeout, user_id}, socket) do
    if socket.assigns.user_id != user_id do
      push(socket, "user_left", %{
        user_id: user_id, 
        reason: "timeout"
      })
    end
    {:noreply, socket}
  end
  
  # Handle heartbeat from ReliableSessionState
  @impl true
  def handle_info({:heartbeat, sequence}, socket) do
    # Update heartbeat in state
    ReliableSessionState.update_heartbeat(socket.assigns.user_id)
    
    # Send heartbeat to client
    push(socket, "heartbeat", %{
      sequence: sequence,
      timestamp: System.system_time(:millisecond)
    })
    
    {:noreply, socket}
  end
  
  # Handle incoming events
  @impl true
  def handle_in("draw", payload, socket) do
    handle_event("draw", payload, socket)
  end
  
  @impl true
  def handle_in("circle", payload, socket) do
    handle_event("circle", payload, socket)
  end
  
  @impl true
  def handle_in("move", payload, socket) do
    handle_event("move", payload, socket)
  end
  
  @impl true
  def handle_in("delete", payload, socket) do
    handle_event("delete", payload, socket)
  end
  
  # Handle acknowledgments
  @impl true
  def handle_in("ack", %{"sequence_number" => sequence_number}, socket) do
    user_id = socket.assigns.user_id
    ReliableSessionState.acknowledge_event(user_id, sequence_number)
    
    Logger.debug("User #{user_id} acknowledged event #{sequence_number}")
    
    {:reply, :ok, socket}
  end
  
  # Handle gap reports
  @impl true
  def handle_in("gap_report", %{"missing_sequences" => missing_sequences}, socket) do
    # Get the missing events
    events = ReliableSessionState.get_events_by_sequences(missing_sequences)
    
    # Send them back
    push(socket, "resend_events", %{
      events: events,
      reason: "gap_recovery"
    })
    
    Logger.info("Resent #{length(events)} events to #{socket.assigns.user_id} for gap recovery")
    
    {:reply, :ok, socket}
  end
  
  # Handle heartbeat responses
  @impl true
  def handle_in("heartbeat_response", %{"sequence" => _sequence}, socket) do
    ReliableSessionState.update_heartbeat(socket.assigns.user_id)
    {:reply, :ok, socket}
  end
  
  # Handle connection status requests
  @impl true
  def handle_in("connection_status", _payload, socket) do
    pending_acks = ReliableSessionState.get_pending_acks()
    user_pending = Map.get(pending_acks, socket.assigns.user_id, [])
    current_sequence = ReliableSessionState.get_current_sequence()
    
    status = %{
      connection_id: socket.assigns.connection_id,
      current_sequence: current_sequence,
      pending_events: length(user_pending),
      last_heartbeat: System.system_time(:millisecond)
    }
    
    {:reply, {:ok, status}, socket}
  end
  
  # Channel cleanup
  @impl true
  def terminate(_reason, socket) do
    user_id = socket.assigns.user_id
    
    # Remove from reliable state
    ReliableSessionState.remove_user(user_id)
    
    # Notify others via PubSub
    PubSub.broadcast_from(
      CollaborativeWebsocket.PubSub,
      self(),
      "session:room",
      {:user_left, user_id}
    )
    
    Logger.info("User #{user_id} disconnected")
    :ok
  end
  
  # Private helper functions
  
  defp handle_event(event_type, payload, socket) do
    user_id = socket.assigns.user_id
    
    # Create event structure
    event = %{
      user_id: user_id,
      event: Map.put(payload, "type", event_type)
    }
    
    # Add to reliable session state (this will auto-broadcast)
    case ReliableSessionState.add_event(event) do
      {:ok, sequence_number, _enhanced_event} ->
        Logger.debug("User #{user_id} created event #{sequence_number}")
        {:reply, {:ok, %{sequence_number: sequence_number}}, socket}
      
      {:error, reason} ->
        Logger.error("Failed to add event for user #{user_id}: #{reason}")
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end
  
  defp generate_connection_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
  
  defp generate_sync_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)  
  end
  
  defp generate_event_ref do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end