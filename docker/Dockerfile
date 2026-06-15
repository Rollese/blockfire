# Headless Godot image that runs the Blockfire project as either the dedicated server or
# the bot fleet — the role is chosen by the container `command` (see docker-compose.yml).
# Godot 4.x has no separate server binary; the normal Linux binary is run with --headless.
#
# Build context must be the REPO ROOT, e.g.:
#   docker build -f docker/Dockerfile -t blockfire:latest .
FROM debian:bookworm-slim

# Godot version to download. Override at build time if needed:
#   --build-arg GODOT_VERSION=4.6-stable
# Or supply a different URL / a custom build (see docker/README.md "Godot binary").
ARG GODOT_VERSION=4.6-stable
ARG GODOT_URL=https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip

# Runtime libs the Godot binary links at load time (no GPU is used under --headless, but the
# shared objects must be present for the dynamic loader). Trim if your base already has them.
RUN apt-get update && apt-get install -y --no-install-recommends \
		ca-certificates curl unzip \
		libfontconfig1 libgl1 libglu1-mesa \
		libxcursor1 libxinerama1 libxrandr2 libxi6 libxkbcommon0 libasound2 \
	&& rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/godot.zip "${GODOT_URL}" \
	&& unzip -q /tmp/godot.zip -d /tmp/godot \
	&& mv /tmp/godot/Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot \
	&& chmod +x /usr/local/bin/godot \
	&& rm -rf /tmp/godot.zip /tmp/godot \
	&& godot --version

WORKDIR /app
COPY . /app

# Import once at build so the project is ready to run (regenerates .godot for this image).
# Never pipe godot through head/tail (it can hang on first run); redirect to a file.
RUN godot --headless --path /app --import > /tmp/import.log 2>&1 || true; \
	tail -n 20 /tmp/import.log

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Args after the image name are passed to godot (the compose `command` supplies the role).
ENTRYPOINT ["/entrypoint.sh"]
CMD ["--headless", "--path", "/app", "--", "--server", "--port=27240"]
