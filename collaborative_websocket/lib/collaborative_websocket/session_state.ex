defmodule CollaborativeWebsocket.SessionState do
  use GenServer
  
  # Client API
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  def add_user(user_id, pid) do
    GenServer.call(__MODULE__, {:add_user, user_id, pid})
  end
  
  def remove_user(user_id) do
    GenServer.call(__MODULE__, {:remove_user, user_id})
  end
  
  def add_event(event) do
    GenServer.call(__MODULE__, {:add_event, event})
  end
  
  def get_events_since(version) do
    GenServer.call(__MODULE__, {:get_events_since, version})
  end
  
  def get_current_version do
    GenServer.call(__MODULE__, :get_current_version)
  end
  
  def get_users do
    GenServer.call(__MODULE__, :get_users)
  end
  
  # Server callbacks
  
  @impl true
  def init(_) do
    {:ok, %{
      events: [],
      version: 0,
      users: %{}
    }}
  end
  
  @impl true
  def handle_call({:add_user, user_id, pid}, _from, state) do
    new_users = Map.put(state.users, user_id, pid)
    new_state = %{state | users: new_users}
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:remove_user, user_id}, _from, state) do
    new_users = Map.delete(state.users, user_id)
    new_state = %{state | users: new_users}
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:add_event, event}, _from, state) do
    new_version = state.version + 1
    new_events = [event | state.events]
    
    # Keep only the last 1000 events for memory management
    trimmed_events = if length(new_events) > 1000 do
      Enum.take(new_events, 1000)
    else
      new_events
    end
    
    new_state = %{state | 
      events: trimmed_events, 
      version: new_version
    }
    
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:get_events_since, nil}, _from, state) do
    # New user, return all events (most recent first, so reverse for chronological order)
    events = Enum.reverse(state.events)
    {:reply, events, state}
  end
  
  @impl true
  def handle_call({:get_events_since, version}, _from, state) when is_integer(version) do
    # Return events after the given version
    events = state.events
    |> Enum.filter(fn event -> event.timestamp > version end)
    |> Enum.reverse()  # Reverse for chronological order
    
    {:reply, events, state}
  end
  
  @impl true
  def handle_call({:get_events_since, version}, _from, state) when is_binary(version) do
    case Integer.parse(version) do
      {parsed_version, ""} ->
        handle_call({:get_events_since, parsed_version}, nil, state)
      _ ->
        # Invalid version, treat as new user
        handle_call({:get_events_since, nil}, nil, state)
    end
  end
  
  @impl true
  def handle_call(:get_current_version, _from, state) do
    {:reply, state.version, state}
  end
  
  @impl true
  def handle_call(:get_users, _from, state) do
    {:reply, Map.keys(state.users), state}
  end
end