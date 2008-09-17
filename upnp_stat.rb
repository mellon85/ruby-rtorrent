require 'rubygems'
require 'UPnP'
require 'thread'
require 'SCGIxml'
require 'pp'

TRUST_ROUTER_LINK_SPEED = true
RTORRENT_SOCKET = "/home/dario/.rtorrent/socket"

LINE_UP_MAX         = 30
LINE_DOWN_MAX       = 250

MIN_UP              = 5
MIN_DOWN            = 10

MAX_CHANGE          = 3
INTERVAL            = 1
PROBE_INTERVAL      = 5
RTORRENT_INTERVAL   = 2

ROUTER_CORRECTION   = 0.8
UPNP_CONVERSION     = 1024*8
RTORRENT_CONVERSION = 1024

CRIT_UP             = 5
CRIT_DOWN           = 30

def putsv(s,v)
    puts "#{s} #{v}"
    puts "#{s} #{v/UPNP_CONVERSION}"
    puts "#{s} #{v/RTORRENT_CONVERSION}"
end

def get_average(v)
    a=0
    for i in 0..(v.length-2)
        a = a + v[i+1]-v[i]
    end
    return a/(v.length-1)
end


class UPnPDaemon

    def initialize()
        @upload    = [0]*PROBE_INTERVAL
        @download  = [0]*PROBE_INTERVAL
        @semaphore = Mutex.new

        @upnp = UPnP::UPnP.new
        @daemon = Thread.new do 
            while true do
              sent = @upnp.totalBytesSent().to_i
              recv = @upnp.totalBytesReceived().to_i
              @semaphore.synchronize {
                @upload = @upload[1,PROBE_INTERVAL]+[sent]
                @download = @download[1,PROBE_INTERVAL]+[recv]
              }
             sleep(1)
            end
        end
    end

    # values are in kbit/INTERVAL
    def get_upload()
        up = 0
        @semaphore.synchronize { up = get_average(@upload) }
        return up
    end

    # values are in kbit/INTERVAL
    def get_download()
        down = 0
        @semaphore.synchronize { down = get_average(@download) }
        return down
    end

    def linkBitrate()
        @upnp.maxLinkBitrates()
    end

    private
end

$d = UPnPDaemon.new
puts "Statistics"

link_down, link_up = $d.linkBitrate()
MAX_UP   = link_up.to_i / UPNP_CONVERSION
MAX_DOWN = link_down.to_i / UPNP_CONVERSION
puts "Router reported speeds"
puts "max up #{MAX_UP}"
puts "max down #{MAX_DOWN}"

rtorrent        = SCGIXMLClient.new([RTORRENT_SOCKET,"/RPC2"])
rtorrent_up_a   = [0]*PROBE_INTERVAL
rtorrent_down_a = [0]*PROBE_INTERVAL

while true do
    sleep(RTORRENT_INTERVAL)

    # query rtorrent for data
    rtorrent_max_up, rtorrent_max_down, list = rtorrent.multicall(["get_download_rate"],["get_upload_rate"],["download_list"]) 
    rtorrent_max_up = rtorrent_max_up.to_i / RTORRENT_CONVERSION
    rtorrent_max_down = rtorrent_max_down.to_i / RTORRENT_CONVERSION

    puts "rtorrent max down #{rtorrent_max_down}"
    puts "rtorrent max up #{rtorrent_max_up}"

    puts rtorrent.call("download_list")

    # get total rates data
#    request = []
    data = []
    list.each do |d|
        data.push(rtorrent.call("d.get_up_rate",d))
        data.push(rtorrent.call("d.get_down_rate",d))
        #request.push(["d.get_up_rate",d])
        #request.push(["d.get_down_rate",d])
    end
    #pp request
    #data = rtorrent.multicall(request)
    pp data
    
    # calculate total rates
    rtorrent_up = 0
    rtorrent_down = 0
    for i in (0..list.length)
        rtorrent_up   += data[i*2].to_i
        rtorrent_down += data[i*2+1].to_i
    end
    rtorrent_up_a   = rtorrent_up_a[1,PROBE_INTERVAL]   + [rtorrent_up]
    rtorrent_down_a = rtorrent_down_a[1,PROBE_INTERVAL] + [rtorrent_down]
    rtorrent_up     = get_average(rtorrent_up_a)
    rtorrent_down   = get_average(rtorrent_down_a)
    putsv("rtorrent down",rtorrent_down)
    putsv("rtorrent up",rtorrent_up)
    putsv("router down",$d.get_download)
    putsv("router up",$d.get_upload)
    router_up = $d.get_upload
    router_down = $d.get_download

    # get bandwidth of other programs
    other_up = router_up - rtorrent_up
    other_down = router_down - rtorrent_down
    putsv("other down",other_down)
    putsv("other up",other_up)

end

