FROM ruby:3.4-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    libssl-dev \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./

RUN gem update --system && gem install bundler \
  && bundle config set without 'development test' \
  && bundle install --jobs=4 --retry=3 \
  # Force eventmachine to rebuild WITH openssl support
  && bundle pristine eventmachine

COPY . .

RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

ENTRYPOINT ["bundle", "exec", "ruby", "src/mastodon_to_slack.rb"]
