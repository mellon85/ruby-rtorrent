require 'rubygems'

begin
    require 'UPnP'
rescue
    puts "Need gem mupnp"
end
require 'thread'
require 'SCGIxml'
require 'pp'

TRUST_ROUTER_LINK_SPEED = true
RTORRENT_SOCKET = "/home/dario/.rtorrent/socket"

LINE_UP_MAX         = 30
LINE_DOWN_MAX       = 250

MIN_UP              = 5
MIN_DOWN            = 10

MAX_CHANGE_UP       = 5
MAX_CHANGE_DOWN     = 50
INTERVAL            = 1
PROBE_INTERVAL      = 5
RTORRENT_INTERVAL   = 2

ROUTER_CORRECTION   = 0.9
UPNP_CONVERSION     = 1024*8
RTORRENT_CONVERSION = 1024

CRIT_UP             = 5
CRIT_DOWN           = 30

DEBUG = 1
def debug(x)
    puts x if DEBUG == 1
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

if TRUST_ROUTER_LINK_SPEED == true
    link_down, link_up = $d.linkBitrate()
    MAX_UP   = (link_up.to_i   * ROUTER_CORRECTION) / UPNP_CONVERSION
    MAX_DOWN = (link_down.to_i * ROUTER_CORRECTION) / UPNP_CONVERSION
else
    MAX_UP   = LINE_UP_MAX
    MAX_DOWN = LINE_DOWN_MAX
end
debug "MAX_UP = #{MAX_UP}"
rtorrent        = SCGIXMLClient.new([RTORRENT_SOCKET,"/RPC2"])
rtorrent_up_a   = [0]*PROBE_INTERVAL
rtorrent_down_a = [0]*PROBE_INTERVAL

while true do
    sleep(RTORRENT_INTERVAL)

    # query rtorrent for data
    rtorrent_max_up, rtorrent_max_down, list = rtorrent.multicall(["get_download_rate"],["get_upload_rate"],["download_list"]) 

    # get kB
    rtorrent_max_down /= RTORRENT_CONVERSION
    rtorrent_max_up   /= RTORRENT_CONVERSION
    
    #@TODO should use multicall but i am experiencing problems
    # get total rates data
    #request = []
    data = []
    list.each do |d|
        data.push(rtorrent.call("d.get_up_rate",d))
        data.push(rtorrent.call("d.get_down_rate",d))
        #request += ["d.get_up_rate",d] + ["d.get_down_rate",d] 
    end
    #data = rtorrent.multicall(request)
    
    # calculate total rates
    rtorrent_up = 0
    rtorrent_down = 0
    for i in (0..list.length)
        rtorrent_up   += data[i*2].to_i
        rtorrent_down += data[i*2+1].to_i
    end
    rtorrent_up_a   = rtorrent_up_a[1,PROBE_INTERVAL]   + [rtorrent_up]
    rtorrent_down_a = rtorrent_down_a[1,PROBE_INTERVAL] + [rtorrent_down]
    rtorrent_up     = get_average(rtorrent_up_a)   / RTORRENT_CONVERSION
    rtorrent_down   = get_average(rtorrent_down_a) / RTORRENT_CONVERSION

    debug "rtorrent #{get_average(rtorrent_up_a)},#{get_average(rtorrent_down_a)}"
    # get info from the router about used bandwidth
    router_up   = $d.get_upload   / 1024 # / UPNP_CONVERSION
    router_down = $d.get_download / 1024 # / UPNP_CONVERSION
    debug "Router up: #{router_up}"
    debug "Router down: #{router_down}"
    debug "Rtorrent up: #{rtorrent_up}"
    debug "Rtorrent down: #{rtorrent_down}"

    # get bandwidth of other programs
    other_up = router_up - rtorrent_up
    other_down = router_down - rtorrent_down

    ### ALGORITHM
    # VARIABLES:
    # router_up, router_down (avg over 5s)
    # rtorrent_max_up, rtorrent_max_down
    # rtorrent_up,rtorrent_down (avg over 5s)
    # other_up, other_down (avg over 5s)
    # store result in rtorrent_new_down, rtorrent_new_up
    
    rtorrent_new_down = MAX_DOWN - other_down - CRIT_DOWN
    rtorrent_new_up   = MAX_UP   - other_up   - CRIT_UP
    debug "#{rtorrent_new_down} = #{MAX_DOWN} - #{other_down} - #{CRIT_DOWN}"
    debug "#{rtorrent_new_up}   = #{MAX_UP}   - #{other_up}   - #{CRIT_UP}"
   
    ### END
    #@TODO Malfunctioning code
    #diff = rtorrent_new_down - rtorrent_down
    #if diff.abs > MAX_CHANGE_DOWN
    #    if diff > 0 then
    #        rtorrent_new_down = rtorrent_down + MAX_CHANGE_DOWN
    #    else
    #        rtorrent_new_down = rtorrent_down - MAX_CHANGE_DOWN
    #    end
    #end
    #diff = rtorrent_new_up - rtorrent_up
    #if diff.abs > MAX_CHANGE_UP
    #    if diff > 0 then
    #        rtorrent_new_up = rtorrent_up + MAX_CHANGE_UP
    #    else
    #        rtorrent_new_up = rtorrent_up - MAX_CHANGE_UP
    #    end
    #end

    # apply the limits
    if rtorrent_new_down < MIN_DOWN and MIN_DOWN != 0
        rtorrent_new_down = MIN_DOWN
    elsif rtorrent_new_down > MAX_DOWN and MAX_DOWN != 0
        rtorrent_new_down = MAX_DOWN
    end
    if rtorrent_new_up < MIN_UP and MIN_UP != 0
        rtorrent_new_up = MIN_UP
    elsif rtorrent_new_up > MAX_UP and MAX_UP != 0
        rtorrent_new_up = MAX_UP
    end

    rtorrent_new_up = rtorrent_new_up.to_i
    rtorrent_new_down = rtorrent_new_down.to_i

    #@TODO should use multicall but i am experiencing problems
    # if needed apply the changes
    #request = []
    if rtorrent_new_down != rtorrent_max_down
        #request += ["set_download_rate","#{rtorrent_new_down*RTORRENT_CONVERSION}"]
        debug "fixing download to: #{rtorrent_new_down}"
        rtorrent.call("set_download_rate","#{rtorrent_new_down*RTORRENT_CONVERSION}")
    end
    if rtorrent_new_up != rtorrent_max_up
        #request += ["set_upload_rate","#{rtorrent_new_up*RTORRENT_CONVERSION}"]
        debug "fixing upload to: #{rtorrent_new_up}"
        rtorrent.call("set_upload_rate","#{rtorrent_new_up*RTORRENT_CONVERSION}")
    end
    #if request.length > 0 then
    #    rtorrent.multicall(request)
    #end
end

