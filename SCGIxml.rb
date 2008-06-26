#! /usr/bin/ruby
# Author: Dario Meloni <mellon85@gmail.com>

require 'xmlrpc/client'
require 'xmlrpcs'
require 'socket'
require 'scgi'

class SCGIXMLClient < XMLRPC::ClientS
    def new_socket( info, async )
        SCGIWrappedSocket.new(UNIXSocket.new(info.first),info.last)
    end
end

class SCGIWrappedSocket

    def initialize( sock, uri, method="POST" )
        @sock = sock
        @uri = uri
        @method = method
    end

    def write(x)
        @sock.write(SCGI::Wrapper.wrap(x,@uri,@method))
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