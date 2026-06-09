FROM rust:bookworm AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install mdbook --version 0.4.52 --locked

WORKDIR /app

COPY book.toml ./
COPY tools ./tools
COPY src ./src

ARG SECODER_BASE_DOMAIN=t.secoder.net
ENV SECODER_BASE_DOMAIN=${SECODER_BASE_DOMAIN}

RUN mdbook build

FROM nginx:alpine AS runtime

COPY --from=build /app/book /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
