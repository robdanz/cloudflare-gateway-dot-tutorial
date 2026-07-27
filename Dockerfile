FROM alpine:latest

RUN apk add --no-cache \
    stubby \
    bind-tools \
    curl \
    bash \
    gettext

COPY stubby.yml.tpl /etc/stubby/stubby.yml.tpl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
