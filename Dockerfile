FROM registry.fedoraproject.org/fedora-minimal:42

RUN microdnf install -y --nodocs --setopt=install_weak_deps=0 \
      fwupd \
      fwupd-efi \
      efibootmgr \
      util-linux \
      e2fsprogs \
      dosfstools \
      python3 \
      coreutils \
      bash \
      jq \
    && microdnf clean all \
    && rm -rf /var/cache/dnf

COPY scripts/esp-detect.sh /usr/local/bin/esp-detect
COPY scripts/patch-efi-vars.py /usr/local/bin/patch-efi-vars
COPY scripts/entrypoint.sh /usr/local/bin/fwupd-container

RUN chmod +x /usr/local/bin/esp-detect \
             /usr/local/bin/patch-efi-vars \
             /usr/local/bin/fwupd-container

ENV FWUPD_UEFI_ESP_PATH=/boot/efi

ENTRYPOINT ["fwupd-container"]
CMD ["help"]
