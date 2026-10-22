FROM rust:1.99.1-alpine@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9 AS build

RUN apk upgrade --no-cache && apk add --no-cache bash jq ca-certificates musl-dev \
    && cargo install mdbook --version 0.5.4 -j 4 \
    && mdbook --version

WORKDIR /app

COPY book.toml ./
COPY tools ./tools
COPY src ./src

ARG SECODER_BASE_DOMAIN=t.secoder.net
ENV SECODER_BASE_DOMAIN=${SECODER_BASE_DOMAIN}

RUN mdbook build

FROM nginx:stable-alpine@sha256:c59d1f8b1e0e42da75be973424cd72e23f7f8adfb54e982f4d1cd0216a5a5576 AS runtime
RUN apk upgrade --no-cache && update-ca-certificates

COPY --from=build /app/book /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
