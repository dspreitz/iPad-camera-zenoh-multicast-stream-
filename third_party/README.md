# third_party

Ablage für den **gepatchten zenohd 1.10.1** (UDP-Multicast-Fixes aus eclipse-zenoh/zenoh #2819, #2820, #2821), den `docker/Dockerfile.zenohd` mit `--build-arg VARIANT=patched` verwendet. Das Binary ist nicht im Repo (`.gitignore`).

Erwarteter Dateiname: `third_party/zenohd-1.10.1-patched-aarch64` (Linux aarch64, glibc).

Bezug:

- **Fertiger Build** aus dem GitHub-Actions-Lauf des Forks (Artefakte werden 90 Tage aufbewahrt):
  ```bash
  gh run download 36635927703 -R dspreitz/zenoh -n zenohd-1.10.1-multicast-fixes-aarch64-unknown-linux-gnu -D /tmp/zenohd
  tar -xzf /tmp/zenohd/*.tar.gz -C /tmp/zenohd
  cp /tmp/zenohd/zenohd-1.10.1-multicast-fixes-aarch64-unknown-linux-gnu/zenohd third_party/zenohd-1.10.1-patched-aarch64
  ```
- **Selbst bauen** aus dem Branch `multicast-fixes-1.10.1` von https://github.com/dspreitz/zenoh (`cargo build --release -p zenohd`).

Die Variante `stock` (offizielles Release 1.10.1) braucht nichts aus diesem Ordner.
