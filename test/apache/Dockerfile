FROM alpine:latest
RUN apk add --no-cache apache2 apache2-webdav apache2-utils apr-util-dbm_gdbm \
    && mkdir -p /srv/dav /var/lib/dav \
    && chown apache:apache /srv/dav /var/lib/dav \
    && htpasswd -bc /etc/apache2/dav.passwd test test
COPY dav.conf mpm.conf /etc/apache2/conf.d/
EXPOSE 80
CMD ["httpd", "-DFOREGROUND"]
