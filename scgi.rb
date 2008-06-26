#! /usr/bin/ruby
# Author: Dario Meloni <mellon85@gmail.com>

module SCGI

class Wrapper

    def self.wrap( content, uri, method="POST" )
        null="\0"
        header = "CONTENT_LENGTH\0#{content.length}\0SCGI#{null}1\0REQUEST_METHOD\0#{method}\0REQUEST_URI\0#{uri}\0"
        return "#{header.length}:#{header},#{content}"
    end

end
end
