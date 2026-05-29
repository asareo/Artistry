FROM golang:1.24

WORKDIR /go/src/github.com/NghiaTranUIT/artify-core
ENV GOTOOLCHAIN=auto

RUN apt-get update && apt-get install -y python3 python3-pip
RUN pip3 install requests psycopg2-binary --break-system-packages

RUN go install -tags sqlite github.com/gobuffalo/pop/v6/soda@v6.1.1

ADD . /go/src/github.com/NghiaTranUIT/artify-core

RUN go mod download

EXPOSE 7300
