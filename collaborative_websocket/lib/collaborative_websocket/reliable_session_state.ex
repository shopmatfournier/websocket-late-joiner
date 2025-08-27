defmodule CollaborativeWebsocket.ReliableSessionState do
  @moduledoc """
  Enhanced session state with reliable event delivery using GenServer.
  
  Features:
  - Sequence-based event ordering
  - Event acknowledgment tracking
  - Gap detection and recovery
  - Heartbeat monitoring
  - Automatic cleanup
  """
  
  use GenServer
  
  alias Phoenix.PubSub
  
  # Client API
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  @doc "Add user with connection tracking"
  def add_user(user_id, channel_pid, last_known_sequence \\ 0) do
    GenServer.call(__MODULE__, {:add_user, user_id, channel_pid, last_known_sequence})
  end
  
  @doc "Remove user and cleanup"
  def remove_user(user_id) do
    GenServer.call(__MODULE__, {:remove_user, user_id})
  end
  
  @doc "Add event with automatic sequencing"
  def add_event(event) do
    GenServer.call(__MODULE__, {:add_event, event})
  end
  
  @doc "Acknowledge event received by user"  
  def acknowledge_event(user_id, sequence_number) do
    GenServer.call(__MODULE__, {:acknowledge_event, user_id, sequence_number})
  end
  
  @doc "Get events since last sequence for catchup"
  def get_events_since(last_sequence) do
    GenServer.call(__MODULE__, {:get_events_since, last_sequence})
  end
  
  @doc "Get specific events by sequence numbers"
  def get_events_by_sequences(sequences) do
    GenServer.call(__MODULE__, {:get_events_by_sequences, sequences})
  end
  
  @doc "Get current sequence number"
  def get_current_sequence do
    GenServer.call(__MODULE__, :get_current_sequence)
  end
  
  @doc "Update heartbeat for user"
  def update_heartbeat(user_id) do
    GenServer.cast(__MODULE__, {:update_heartbeat, user_id})
  end
  
  @doc "Get users with pending acknowledgments"
  def get_pending_acks do
    GenServer.call(__MODULE__, :get_pending_acks)
  end
  
  # Server callbacks
  
  @impl true
  def init(_) do
    # Schedule cleanup and heartbeat checks
    :timer.send_interval(30_000, self(), :cleanup_and_heartbeat)
    
    {:ok, %{
      events: %{},              # sequence => event
      sequence_counter: 0,
      users: %{},              # user_id => user_info
      event_acknowledgments: %{}, # sequence => [user_ids that acked]
      max_events: 10_000,
      heartbeat_timeout: 90_000  # 90 seconds
    }}
  end
  
  @impl true
  def handle_call({:add_user, user_id, channel_pid, last_known_sequence}, _from, state) do
    user_info = %{
      channel_pid: channel_pid,
      last_ack_sequence: last_known_sequence,
      last_heartbeat: System.system_time(:millisecond),
      pending_events: MapSet.new()
    }
    
    new_users = Map.put(state.users, user_id, user_info)
    new_state = %{state | users: new_users}
    
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:remove_user, user_id}, _from, state) do
    new_users = Map.delete(state.users, user_id)
    
    # Clean up acknowledgments for this user
    new_acks = state.event_acknowledgments
    |> Enum.map(fn {seq, user_list} ->
      {seq, List.delete(user_list, user_id)}
    end)
    |> Enum.into(%{})
    
    new_state = %{state | 
      users: new_users,
      event_acknowledgments: new_acks
    }
    
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:add_event, event}, _from, state) do
    new_sequence = state.sequence_counter + 1
    
    enhanced_event = event
    |> Map.put(:sequence_number, new_sequence)
    |> Map.put(:timestamp, System.system_time(:millisecond))
    |> Map.put(:id, generate_event_id())
    
    new_events = Map.put(state.events, new_sequence, enhanced_event)
    
    # Track which users need to acknowledge this event
    user_ids = Map.keys(state.users)
    new_acks = Map.put(state.event_acknowledgments, new_sequence, [])
    
    # Add to each user's pending events
    new_users = state.users
    |> Enum.map(fn {user_id, user_info} ->
      updated_info = %{user_info | 
        pending_events: MapSet.put(user_info.pending_events, new_sequence)
      }
      {user_id, updated_info}
    end)
    |> Enum.into(%{})
    
    new_state = %{state | 
      events: cleanup_old_events(new_events, state.max_events),
      sequence_counter: new_sequence,
      event_acknowledgments: new_acks,
      users: new_users
    }
    
    # Broadcast to all users with reliability tracking
    broadcast_event_with_tracking(enhanced_event, user_ids)
    
    {:reply, {:ok, new_sequence, enhanced_event}, new_state}
  end
  
  @impl true
  def handle_call({:acknowledge_event, user_id, sequence_number}, _from, state) do
    # Update user's ack status
    new_users = case Map.get(state.users, user_id) do
      nil -> state.users
      user_info ->
        updated_info = %{user_info |
          last_ack_sequence: max(user_info.last_ack_sequence, sequence_number),
          pending_events: MapSet.delete(user_info.pending_events, sequence_number)
        }
        Map.put(state.users, user_id, updated_info)
    end
    
    # Update acknowledgment tracking
    new_acks = case Map.get(state.event_acknowledgments, sequence_number) do
      nil -> state.event_acknowledgments
      ack_list ->
        updated_list = [user_id | ack_list] |> Enum.uniq()
        Map.put(state.event_acknowledgments, sequence_number, updated_list)
    end
    
    new_state = %{state | 
      users: new_users,
      event_acknowledgments: new_acks
    }
    
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:get_events_since, last_sequence}, _from, state) do
    events = state.events
    |> Enum.filter(fn {seq, _event} -> seq > last_sequence end)
    |> Enum.sort_by(fn {seq, _event} -> seq end)
    |> Enum.map(fn {_seq, event} -> event end)
    
    {:reply, events, state}
  end
  
  @impl true
  def handle_call({:get_events_by_sequences, sequences}, _from, state) do
    events = sequences
    |> Enum.map(fn seq -> Map.get(state.events, seq) end)
    |> Enum.reject(&is_nil/1)
    
    {:reply, events, state}
  end
  
  @impl true
  def handle_call(:get_current_sequence, _from, state) do
    {:reply, state.sequence_counter, state}
  end
  
  @impl true
  def handle_call(:get_pending_acks, _from, state) do
    pending = state.users
    |> Enum.map(fn {user_id, user_info} ->
      {user_id, MapSet.to_list(user_info.pending_events)}
    end)
    |> Enum.into(%{})
    
    {:reply, pending, state}
  end
  
  @impl true
  def handle_cast({:update_heartbeat, user_id}, state) do
    new_users = case Map.get(state.users, user_id) do
      nil -> state.users
      user_info ->
        updated_info = %{user_info | last_heartbeat: System.system_time(:millisecond)}
        Map.put(state.users, user_id, updated_info)
    end
    
    {:noreply, %{state | users: new_users}}
  end
  
  @impl true
  def handle_info(:cleanup_and_heartbeat, state) do
    current_time = System.system_time(:millisecond)
    
    # Find expired users
    {active_users, expired_users} = state.users
    |> Enum.split_with(fn {_user_id, user_info} ->
      current_time - user_info.last_heartbeat < state.heartbeat_timeout
    end)
    
    # Clean up expired users
    new_users = Enum.into(active_users, %{})
    
    # Notify about expired users
    expired_users
    |> Enum.each(fn {user_id, _user_info} ->
      PubSub.broadcast(
        CollaborativeWebsocket.PubSub,
        "session:room",
        {:user_timeout, user_id}
      )
    end)
    
    # Send heartbeat to active users
    active_users
    |> Enum.each(fn {_user_id, user_info} ->
      send(user_info.channel_pid, {:heartbeat, state.sequence_counter})
    end)
    
    new_state = %{state | users: new_users}
    {:noreply, new_state}
  end
  
  # Private functions
  
  defp generate_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
  
  defp cleanup_old_events(events, max_events) do
    if map_size(events) > max_events do
      events
      |> Enum.sort_by(fn {seq, _event} -> seq end)
      |> Enum.drop(map_size(events) - max_events)
      |> Enum.into(%{})
    else
      events
    end
  end
  
  defp broadcast_event_with_tracking(event, user_ids) do
    PubSub.broadcast(
      CollaborativeWebsocket.PubSub,
      "session:room",
      {:reliable_event, event, user_ids}
    )
  end
end