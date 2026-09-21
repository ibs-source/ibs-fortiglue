FROM alpine:3.22

LABEL org.opencontainers.image.title="ibs-fortiglue" \
      org.opencontainers.image.description="Nightly synchronisation between IT Glue and the Fortinet services" \
      org.opencontainers.image.source="https://github.com/ibs-source/ibs-fortiglue" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache bash ca-certificates curl jq && \
    adduser -D -H -s /sbin/nologin -g fortiglue fortiglue

COPY ./library /library
COPY ./wrapper.sh /wrapper.sh

RUN chmod 0755 /wrapper.sh && chmod -R a+rX /library

USER fortiglue

STOPSIGNAL SIGTERM

# Exec form: the script becomes process one and receives the signals itself.
# The handler runs as soon as the call in flight returns, which with the
# default deadlines can take up to two minutes: a scheduler that wants the
# container gone earlier should lower ENVIRONMENT_HTTP_TIMEOUT or raise its own
# stop timeout, because a kill leaves the appliance session open.
ENTRYPOINT ["/wrapper.sh"]
