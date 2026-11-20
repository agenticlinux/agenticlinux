# The image of the cloud-init qcow2 (cloud/build.sh): the distribution's bootc
# image plus cloud-init, which a NoCloud host seeds the account and SSH key
# through, and a service that stages IMAGE once cloud-init has finished; it
# replaces this system at the next boot. Build from the repository root.
ARG BOOTC=quay.io/fedora/fedora-bootc:45
FROM ${BOOTC}
ARG IMAGE
RUN --mount=type=bind,source=dnf-install.sh,target=/dnf-install.sh /dnf-install.sh cloud-init
COPY cloud/agenticlinux-stage.service /usr/lib/systemd/system/
COPY cloud/stage-hint.sh /etc/profile.d/agenticlinux-stage.sh
COPY cloud/cloud-final-stage.conf /usr/lib/systemd/system/cloud-final.service.d/10-agenticlinux-stage.conf
# The package leaves some units disabled (cloud-init-network on Fedora 45) and
# names them differently on other releases: enable whichever exist
RUN sed -i "s|@IMAGE@|$IMAGE|" /usr/lib/systemd/system/agenticlinux-stage.service && \
    for u in cloud-init-local cloud-init-main cloud-init-network cloud-init cloud-config cloud-final; do \
      systemctl list-unit-files "$u.service" --no-legend | grep -q . || continue; \
      systemctl enable "$u.service" || exit 1; \
    done && \
    systemctl is-enabled cloud-init-local.service cloud-final.service
# vmmbox's mount point for a macOS home; see the main Dockerfile
COPY usr/lib/tmpfiles.d/agenticlinux-users.conf /usr/lib/tmpfiles.d/
RUN ln -s var/Users /Users
# useradd finds system groups only in /etc/group, not in /usr/lib/group
RUN for g in audio video render; do \
      grep -q "^$g:" /etc/group || getent group "$g" >> /etc/group || exit 1; \
    done
# bootc-dev/bootc#2402: gpt-auto's idle-unmounting /boot automount leaves the
# staged image unfinalized at shutdown
RUN ln -s /dev/null /etc/systemd/system/boot.automount
RUN bootc container lint
