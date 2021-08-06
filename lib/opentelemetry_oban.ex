defmodule OpentelemetryOban do
  @moduledoc """
  OpentelemetryOban uses [telemetry](https://hexdocs.pm/telemetry/) handlers to create
  `OpenTelemetry` spans for Oban events. The Oban telemetry events that are used are documented [here](https://hexdocs.pm/oban/Oban.Telemetry.html).

  ## Usage

  Add in your application start function a call to `setup/0`:

      def start(_type, _args) do
        # this register a tracer for your application
        OpenTelemetry.register_application_tracer(:my_app)

        # this configures the oban tracing
        OpentelemetryOban.setup()

        children = [
          ...
        ]

        ...
      end

  """

  require OpenTelemetry.Tracer
  alias OpenTelemetry.Span
  alias OpentelemetryOban.Reason

  @tracer_id :opentelemetry_oban

  @event_names Enum.flat_map([:job, :producer, :plugin], fn event_kind ->
                 Enum.map([:start, :stop, :exception], fn event_name ->
                   [:oban, event_kind, event_name]
                 end)
               end) ++
                 Enum.flat_map(
                   [:fetch_jobs, :complete_job, :discard_job, :error_job, :snooze_job, :cancel_job],
                   fn event_kind ->
                     Enum.map([:start, :stop, :exception], fn event_name ->
                       [:oban, :engine, event_kind, event_name]
                     end)
                   end
                 ) ++
                 Enum.map([:start, :stop, :exception], fn event_name ->
                   [:oban, :notifier, :notify, event_name]
                 end) ++
                 [[:oban, :circuit, :trip], [:oban, :circuit, :open]]

  @type setup_opts :: [duration() | sampler()]
  @type duration :: {:duration, {atom(), System.time_unit()}}
  @type sampler :: {:sampler, :otel_sampler.instance() | sampler_fun() | nil}

  @type sampler_fun :: (telemetry_data() -> :otel_sampler.instance() | nil)
  @type telemetry_data :: %{event: [atom()], measurements: map(), meta: map()}

  @doc """
  Initializes and configures the telemetry handlers.
  """
  @spec setup(setup_opts()) :: :ok | {:error, :already_exists}
  def setup(opts \\ []) do
    {:ok, otel_phx_vsn} = :application.get_key(@tracer_id, :vsn)
    OpenTelemetry.register_tracer(@tracer_id, otel_phx_vsn)

    config =
      Enum.reduce(
        opts,
        %{duration: %{key: :"oban.duration_ms", timeunit: :millisecond}, sampler: nil},
        fn
          {:duration, {key, timeunit}}, acc when is_atom(key) ->
            %{acc | duration: %{key: key, timeunit: timeunit}}

          {:sampler, sampler}, acc ->
            %{acc | sampler: sampler}
        end
      )

    :telemetry.attach_many(__MODULE__, @event_names, &process_event/4, config)
  end

  @doc false
  def process_event([:oban, event, event_kind, :start] = meta_event, measurements, meta, config) do
    span_name = span_name({event, event_kind}, meta)
    attributes = start_attributes({event, event_kind}, measurements, meta, config)

    start_opts =
      %{kind: :internal}
      |> maybe_put_sampler(config.sampler, %{
        event: meta_event,
        measurements: measurements,
        meta: meta
      })

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, span_name, meta, start_opts)
    |> Span.set_attributes(attributes)
  end

  def process_event([:oban, event_kind, :start] = event, measurements, meta, config) do
    span_name = span_name(event_kind, meta)
    attributes = start_attributes(event_kind, measurements, meta, config)

    start_opts =
      %{kind: :internal}
      |> maybe_put_sampler(config.sampler, %{event: event, measurements: measurements, meta: meta})

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, span_name, meta, start_opts)
    |> Span.set_attributes(attributes)
  end

  def process_event([:oban, event_kind, :stop], measurements, meta, config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    attributes = stop_attributes(event_kind, measurements, meta, config)
    Span.set_attributes(ctx, attributes)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def process_event([:oban, event, event_kind, :stop], measurements, meta, config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    attributes = stop_attributes({event, event_kind}, measurements, meta, config)
    Span.set_attributes(ctx, attributes)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def process_event([:oban, event_kind, :exception], measurements, meta, config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    attributes = exception_attributes(event_kind, measurements, meta, config)
    Span.set_attributes(ctx, attributes)

    register_exception_event(event_kind, ctx, meta)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def process_event([:oban, event, event_kind, :exception], measurements, meta, config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    attributes = exception_attributes({event, event_kind}, measurements, meta, config)
    Span.set_attributes(ctx, attributes)

    register_exception_event({event, event_kind}, ctx, meta)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def process_event([:oban, :circuit = event_kind, :trip], measurements, meta, config) do
    ctx =
      OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "Oban circuit tripped", meta, %{
        kind: :internal
      })

    attributes =
      exception_attributes(event_kind, measurements, meta, config) ++
        [{"oban.event", "circuit_tripped"}]

    Span.set_attributes(ctx, attributes)

    register_exception_event(event_kind, ctx, meta)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp span_name(:job, %{job: %{worker: worker}}) do
    "Oban job #{module_to_string(worker)}"
  end

  defp span_name(:producer, %{queue: queue}) do
    "Oban producer #{queue}"
  end

  defp span_name(:plugin, %{plugin: plugin}) do
    "Oban plugin #{module_to_string(plugin)}"
  end

  defp span_name({:engine, event_name}, _meta) do
    "Oban engine #{event_name}"
  end

  defp span_name({:notifier, event_name}, _meta) do
    "Oban notifier #{event_name}"
  end

  defp start_attributes(
         :job,
         _measurements,
         %{
           job: %{
             worker: worker,
             queue: queue,
             max_attempts: max_attempts,
             attempt: attempt,
             scheduled_at: scheduled_at,
             attempted_at: attempted_at
           }
         },
         _config
       ) do
    [
      {"oban.worker", module_to_string(worker)},
      {"oban.event", "job"},
      {"oban.queue", queue},
      {"oban.max_attempts", max_attempts},
      {"oban.attempt", attempt},
      {"oban.scheduled_at", to_iso8601(scheduled_at)},
      {"oban.attempted_at", to_iso8601(attempted_at)}
    ]
  end

  defp start_attributes(:producer, _measurements, %{queue: queue}, _config) do
    [
      {"oban.event", "producer"},
      {"oban.queue", queue}
    ]
  end

  defp start_attributes(:plugin, _measurements, %{plugin: plugin}, _config) do
    [
      {"oban.event", "plugin"},
      {"oban.plugin", module_to_string(plugin)}
    ]
  end

  defp start_attributes({:engine, event}, _measurements, %{engine: engine}, _config) do
    [
      {"oban.event", "engine"},
      {"oban.engine", module_to_string(engine)},
      {"oban.engine_operation", event}
    ]
  end

  defp start_attributes({:notifier, event}, _measurements, _meta, _config) do
    [
      {"oban.event", "notifier"},
      {"oban.subevent", event}
    ]
  end

  defp start_attributes(_event_kind, _measurements, _meta, _config), do: []

  defp stop_attributes(
         :job,
         %{
           duration: native_duration,
           queue_time: native_queue_time,
           cancelled_at: cancelled_at,
           completed_at: completed_at,
           discarded_at: discarded_at
         },
         %{state: state},
         config
       ) do
    [
      duration_attribute(native_duration, config),
      duration_attribute(native_queue_time, config),
      state_attribute(state),
      {"oban.cancelled_at", to_iso8601(cancelled_at)},
      {"oban.completed_at", to_iso8601(completed_at)},
      {"oban.discarded_at", to_iso8601(discarded_at)}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp stop_attributes(:producer, _measurements, %{dispatched_count: dispatched_count}, _config) do
    [{"oban.dispatched_count", dispatched_count}]
  end

  defp stop_attributes(_event_kind, _measurements, _meta, _config), do: []

  defp exception_attributes(:job, %{duration: native_duration}, %{state: state}, config) do
    [
      duration_attribute(native_duration, config),
      state_attribute(state)
    ]
  end

  defp exception_attributes(_, %{duration: native_duration}, _meta, config) do
    [duration_attribute(native_duration, config)]
  end

  defp exception_attributes(_event_kind, _measurements, _meta, _config), do: []

  defp register_exception_event(_event_kind, ctx, %{
         kind: kind,
         reason: reason,
         stacktrace: stacktrace
       }) do
    {[reason: reason], attrs} = Reason.normalize(reason) |> Keyword.split([:reason])

    exception = Exception.normalize(kind, reason, stacktrace)
    message = Exception.message(exception)

    Span.record_exception(ctx, exception, stacktrace, attrs)
    Span.set_status(ctx, OpenTelemetry.status(:error, message))
  end

  defp state_attribute(state) do
    {"oban.state", state}
  end

  defp duration_attribute(native_duration, %{duration: %{key: key, timeunit: timeunit}}) do
    duration = System.convert_time_unit(native_duration, :native, timeunit)
    {key, duration}
  end

  defp to_iso8601(nil), do: nil
  defp to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp module_to_string(module_name) when is_binary(module_name), do: module_name

  defp module_to_string(module) when is_atom(module) do
    case to_string(module) do
      "Elixir." <> name -> name
      erlang_module -> ":#{erlang_module}"
    end
  end

  defp maybe_put_sampler(opts, nil, _telemetry_data), do: opts

  defp maybe_put_sampler(opts, sampler_fun, telemetry_data) when is_function(sampler_fun) do
    sampler = sampler_fun.(telemetry_data)
    maybe_put_sampler(opts, sampler, telemetry_data)
  end

  defp maybe_put_sampler(opts, sampler, _telemetry_data) do
    Map.put(opts, :sampler, sampler)
  end
end
