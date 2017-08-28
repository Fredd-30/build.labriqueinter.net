FROM debian:armhf
MAINTAINER Émile Morel

COPY init.sh /tmp/init.sh
RUN /bin/bash /tmp/init.sh
RUN apt-get install -y qemu-user-static
