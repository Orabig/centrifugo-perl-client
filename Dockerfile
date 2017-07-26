FROM perl:latest

MAINTAINER benoit.chauvet@gmail.com

RUN cpanm AnyEvent::WebSocket::Client Config::JSON
RUN cpanm REST::Client
