FROM node:24-alpine@sha256:50c8e8ca1d27439048670df5883f32d57cf81cff6233222c893fd0d9884cbd81 AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY eleventy.config.js ./
COPY src/ ./src/
RUN npm run build


FROM nginxinc/nginx-unprivileged:1.31.5-alpine-otel@sha256:eb7e53bb015536fddd519f974bef77b1b88257e1428ab21022460b5a6b33cde7

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

USER nginx

COPY --from=build /app/_site/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
