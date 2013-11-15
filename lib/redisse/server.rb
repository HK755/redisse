require 'redisse'
require 'goliath/api'
require 'rack/accept_media_types'
require 'goliath/runner'
require 'em-hiredis'

module Redisse

  # Public: Run the server based on this API.
  def run
    api = Server.new(self)
    runner = Goliath::Runner.new(ARGV, api)
    runner.app = Goliath::Rack::Builder.build(self, api)
    runner.load_plugins(self.plugins.unshift(Server::Stats))
    runner.run
  end

  class Server < Goliath::API
    require 'redisse/server/stats'

    EVENTS_CONNECTED = "events.connected".freeze
    EVENTS_SENT      = "events.sent".freeze
    EVENTS_MISSED    = "events.missed".freeze

    REDISSE_LONG_POLLING = "redisse.long_polling".freeze
    REDISSE_LONG_POLLING_TIMER = "redisse.long_polling_timer".freeze

    # Public: Delay between receiving a message and closing the connection.
    #
    # Closing the connection is necessary when using long polling, because the
    # client is not able to read the data before the connection is closed. But
    # instead of closing immediately, we delay a bit closing the connection to
    # give a chance for several messages to be sent in a row.
    LONG_POLLING_DELAY = 1

    def initialize(redisse)
      @redisse = redisse
      super()
    end

    def response(env)
      acceptable?(env) or return not_acceptable
      subscribe(env)
      streaming_response(200, {
        'Content-Type' => 'text/event-stream',
        'Cache-Control' => 'no-cache',
        'Connection' => 'keep-alive',
        'X-Accel-Buffering' => 'no',
      })
    end

    def on_close(env)
      unsubscribe(env)
    end

  private

    attr_reader :redisse

    def subscribe(env)
      status[:stats][EVENTS_CONNECTED] += 1
      env['server_sent_events.redis'] = pubsub = connect_pubsub
      channels = redisse.channels(env)
      send_history_events(env, channels)
      env.logger.debug "Subscribing to #{channels}"
      # Redis supports multiple channels for SUBSCRIBE but not em-hiredis
      channels.each do |channel|
        pubsub.subscribe(channel) { |event| send_event(env, event) }
      end
    end

    def unsubscribe(env)
      pubsub = env['server_sent_events.redis']
      return unless pubsub
      pubsub.close_connection
    end

    def send_event(env, event)
      status[:stats][EVENTS_SENT] += 1
      env.logger.debug { "Sending:\n#{event.chomp.chomp}" }
      env.stream_send(event)
      return unless long_polling?(env)
      env[REDISSE_LONG_POLLING_TIMER] ||= EM.add_timer(LONG_POLLING_DELAY) do
        env.stream_close
      end
    end

    def long_polling?(env)
      env.fetch(REDISSE_LONG_POLLING) do
        query_string = env['QUERY_STRING']
        env[REDISSE_LONG_POLLING] = query_string && query_string.include?('polling')
      end
    end

    def send_history_events(env, channels)
      last_event_id = last_event_id(env)
      return unless last_event_id
      EM.next_tick do
        events = events_for_channels(channels, last_event_id)
        env.logger.debug "Sending #{events.size} history events"
        events.each { |event| send_event(env, event) }
      end
    end

    LAST_EVENT_ID_QUERY_PARAM_REGEXP = /(?:^|\&)lastEventId=([^\&\n]*)/

    def last_event_id(env)
      last_event_id = env['HTTP_LAST_EVENT_ID'] ||
        env['QUERY_STRING'] &&
        env['QUERY_STRING'][LAST_EVENT_ID_QUERY_PARAM_REGEXP, 1]
      last_event_id = last_event_id.to_i
      last_event_id.nonzero? && last_event_id
    end

    def events_for_channels(channels, last_event_id)
      events_with_ids = channels.each_with_object([]) { |channel, events|
        channel_events = events_for_channel(channel, last_event_id)
        events.concat(channel_events)
      }.sort_by!(&:last)
      handle_missing_events(events_with_ids, last_event_id)
      events_with_ids.map(&:first)
    end

    def handle_missing_events(events_with_ids, last_event_id)
      first_event_id = events_with_ids.first.last
      if first_event_id == last_event_id
        events_with_ids.shift
      else
        status[:stats][EVENTS_MISSED] += 1
        event = ServerSentEvents.server_sent_event(nil, type: :missedevents)
        events_with_ids.unshift([event])
      end
    end

    def events_for_channel(channel, last_event_id)
      redisse.redis.zrangebyscore(channel, last_event_id, '+inf', with_scores: true)
    end

    def connect_pubsub
      client = EM::Hiredis::PubsubClient.new
      client.configure(redisse.redis_server)
      client.connect
    end

    def acceptable?(env)
      accept_media_types = Rack::AcceptMediaTypes.new(env['HTTP_ACCEPT'])
      accept_media_types.include?('text/event-stream')
    end

    def not_acceptable
      [406,
        { 'Content-Type' => 'text/plain' },
        [
          "406 Not Acceptable\n",
          "This resource can only be represented as text/event-stream.\n"]]
    end

  public

    def options_parser(opts, options)
      default_port = redisse.default_port
      return unless default_port
      options[:port] = default_port
    end

  end
end