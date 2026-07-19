FROM nginxinc/nginx-unprivileged:1.31.3-alpine-otel@sha256:5bd4745a5613f67a90df89b195d90e9db43fc32bb14581647964dba0d893ad9f

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

USER nginx

COPY static/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
