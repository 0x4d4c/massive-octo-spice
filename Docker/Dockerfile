# this strictly for building base images
FROM cifv2:latest
MAINTAINER Wes Young (wes@csirtgadgets.org)

ENV DEBIAN_FRONTEND noninteractive

ADD ansible /srv/cifv2
WORKDIR /srv/cifv2

#RUN ansible-playbook docker.yml -c local -v

ADD ./scripts/start.sh /start.sh
ADD ./scripts/foreground.sh /etc/apache2/foreground.sh
RUN chmod 755 /start.sh
RUN chmod 755 /etc/apache2/foreground.sh

EXPOSE 443

CMD ["/bin/bash", "/start.sh"]
