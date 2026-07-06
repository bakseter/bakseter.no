FROM nginxinc/nginx-unprivileged:1.31.2-alpine-slim@sha256:defdc1caa3ea8401e9b6b2a5d336c1e3d17c6243fa4e12e6c3a466a16fb137ea

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

USER nginx

COPY static/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
