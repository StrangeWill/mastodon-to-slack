# frozen_string_literal: true

require 'bundler/setup'
require 'net/https'
require './lib/colorize.rb'
require './lib/booleanize.rb'
require 'slack-ruby-client'

Bundler.require
Dotenv.load

MASTODON_API_VERSION = 'v1'
MASTODON_TIMELINE    = 'user'
MASTODON_ENDPOINT    = "wss://#{ENV['MASTODON_INSTANCE_HOST']}"        \
                       "/api/#{MASTODON_API_VERSION}/streaming"        \
                       "?access_token=#{ENV['MASTODON_ACCESS_TOKEN']}" \
                       "&stream=#{MASTODON_TIMELINE}"
DISCHARGE_MODE       = ENV.fetch('DISCHARGE_MODE', 'false').booleanize

Slack.configure do |config|
  config.token = ENV["SLACK_BOT_TOKEN"]
end

client = Slack::Web::Client.new

SLACK_CHANNEL_MAP = begin
  channels = []
  cursor   = nil

  loop do
    resp = client.conversations_list(
      types: 'public_channel',
      limit: 1000,
      cursor: cursor
    )

    channels.concat(resp.channels)
    cursor = resp.response_metadata&.next_cursor
    break if cursor.nil? || cursor.empty?
  end

  channels.to_h { |ch| [ch['name'], ch['id']] }
end

def local_account?(account)
  # Local accounts on Mastodon have an acct with *no* "@"
  acct = account&.dig("acct").to_s
  !acct.include?("@")
end

def slack_channel_id_for_tag(tag_name)
  # Mastodon tag["name"] generally comes without the "#"
  # Normalize to lower case to match Slack channel names.
  SLACK_CHANNEL_MAP[tag_name.to_s.downcase]
end


def start_connection(client)
  # https://github.com/faye/faye-websocket-ruby#initialization-options
  ws = Faye::WebSocket::Client.new(MASTODON_ENDPOINT, nil, ping: 60)

  ws.on :open do |_|
    puts 'Connection starts'.green
  end

  ws.on :message do |message|
    response = JSON.parse(message.data)

    if response.dig('event') == 'update'
      payload = JSON.parse(response.dig('payload'))

      # Ignore other-server based activity
      unless local_account?(payload.dig('account'))
        puts "Skipping non-local account: #{payload.dig('account', 'acct')}".yellow if ARGV[0] == '--verbose'
        next
      end

      # The conditional expression below is redundant
      # because it does same thing in `if` statement and `elsif` statement.
      # However it is very complex to combine these statements.

      # ruby style referring to https://github.com/airbnb/ruby/blob/master/README.md#newlines
      if DISCHARGE_MODE                                                                        &&
         (payload.dig('visibility') == 'public' || payload.dig('visibility') == 'unlisted')    &&
         (payload.dig('mentions').empty?        || payload.dig('in_reply_to_account_id').nil?)

        post_to_slack(payload, client)
      elsif payload.dig('account', 'acct') == ENV['MASTODON_USERNAME']                            &&
            (payload.dig('visibility') == 'public' || payload.dig('visibility') == 'unlisted')    &&
            (payload.dig('mentions').empty?        || payload.dig('in_reply_to_account_id').nil?) &&
            !payload.dig('reblogged')

        post_to_slack(payload, client)
      end
    end
  end

  ws.on :close do |_|
    puts 'Connection closed'.pink if ARGV[0] == '--verbose'

    # reopen the connection when closing it
    # https://stackoverflow.com/questions/22941084/faye-websocket-reconnect-to-socket-after-close-handler-gets-triggered
    start_connection(request)

    puts 'Trying to reconnect...'.yellow if ARGV[0] == '--verbose'
  end

  ws.on :error do |event|
    puts "Error occured: #{event.inspect}".red if ARGV[0] == '--verbose'
  end
end

def post_to_slack(payload, client)
  default_channel_id = ENV["SLACK_CHANNEL_ID"]
  if payload["reblog"]
    booster = payload["account"]
    status  = payload["reblog"]
    prefix  = "🔁 #{format_name(booster)} boosted:\n"
  else
    booster = nil
    status  = payload
    prefix  = ""
  end

  account  = status["account"] 
  name     = format_name(account)
  avatar   = account["avatar"]
  url      = status["url"] || status["uri"]

  client.chat_postMessage(
    channel: default_channel_id,
    username: "Mastodon: #{name}",
    icon_url: avatar,
    text: "#{prefix}#{url}",
    unfurl_links: true
  )

  tags = status["tags"] || []
  posted_channels = [default_channel_id]

  tags.each do |tag|
    tag_name = tag["name"]
    next if tag_name.nil? || tag_name.strip.empty?

    channel_id = slack_channel_id_for_tag(tag_name)
    next if channel_id.nil? || posted_channels.include?(channel_id)

    client.chat_postMessage(
      channel:  channel_id,
      username: "Mastodon: #{name}",
      icon_url: avatar,
      text:     "#{prefix}#{url}",
      unfurl_links: true
    )

    posted_channels << channel_id
  end
end

def format_name(account)
  dn = account["display_name"]
  acct = account["acct"]
  dn.nil? || dn.strip.empty? ? acct : "#{dn} (@#{acct})"
end

EM.run do
  start_connection(client)
end
