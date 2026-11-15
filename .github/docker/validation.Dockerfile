FROM ghcr.io/claudiohideki/jrcconversa_hs-prevent@sha256:63e9e4b2caa4bbee0df6da169e3cc406d782eaca80ba787747fbe0572afa7365
ENV BUNDLE_WITHOUT=development BUNDLE_FROZEN=true RAILS_ENV=test
COPY Gemfile Gemfile.lock /app/
RUN bundle install --jobs 4 --retry 2
