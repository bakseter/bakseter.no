FROM node:24-alpine@sha256:50c8e8ca1d27439048670df5883f32d57cf81cff6233222c893fd0d9884cbd81 AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY eleventy.config.js ./
COPY src/ ./src/
RUN npm run build


FROM nginxinc/nginx-unprivileged:1.31.6-alpine-otel@sha256:058b79bea62c027dc42f3ae7b1d6b5e68d1b071459c3bacc14d08afc3b9da0ec

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

USER nginx

COPY --from=build /app/_site/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
