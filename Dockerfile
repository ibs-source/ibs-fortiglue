FROM amd64/alpine:3.17

COPY ./library /library
COPY ./wrapper.sh /wrapper.sh

RUN apk add --update --no-cache curl ca-certificates bash jq uuidgen && \
    adduser -D -g fortiglue fortiglue && \
    chmod +x /wrapper.sh

USER fortiglue

ENTRYPOINT /wrapper.sh