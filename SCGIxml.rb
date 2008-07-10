#! /usr/bin/ruby
# Author: Dario Meloni <mellon85@gmail.com>

require 'xmlrpc/client'
require 'xmlrpc/xmlrpcs'
require 'socket'
require 'scgi'

class SCGIXMLClient < XMLRPC::ClientS
    def new_socket( info, async )
        SCGIWrappedSocket.new(UNIXSocket.new(info.first),info.last)
    end
end

class SCGIWrappedSocket

    attr_accessor :sock, :uri, :method

    def initialize( sock, uri, method="POST" )
        @sock, @uri, @method = sock, uri, method
    end

    def write(x)
        msg = SCGI::Wrapper.wrap(x,@uri,@method)
        r = @sock.write(msg)
        if r != msg.length then
            raise IOException, "Not all the data has been sent (#{r}/#{msg.length})"
        end 
        return x.length
    end 

    def read()
        data = @sock.read()
        # receiving an html response (very dumb parsing)
        # divided in 2
        # 1 -> status + headers
        # 2 -> data
        return data.split("\r\n\r\n").last
   end
end
