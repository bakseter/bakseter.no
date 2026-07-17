FROM nginxinc/nginx-unprivileged:1.31.2-alpine-otel@sha256:1490cbf02ddba36ae75ef947b570166c805a178898ebfbc3bb889e7580820052

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

USER nginx

COPY static/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
