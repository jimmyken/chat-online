-- Copyright (C) 2013 MaMa

timeout = 3000

host = "127.0.0.1"
port = "3306"
database = "platform"
user = "web"
password = "abc"
max_packet_size = 1024 * 1024

max_keepalive = 100
idle_timeout = 60 * 60 * 1000 -- 1 hour in ms

charset = "utf8"


--- tables

chat_message = "chat"
