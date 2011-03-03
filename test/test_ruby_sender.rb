require 'helper'

class TestRubyUdpSender < Test::Unit::TestCase
  context "with ruby sender" do
    setup do
      @host, @port = 'localhost', 12201
      @sender = GELF::RubyUdpSender.new('localhost', 12201)
      @datagrams = %w(d1 d2 d3)
    end

    context "send_datagrams" do
      setup do
        EM.run do
          @sender.send_datagrams(@datagrams)
          EM.stop_event_loop
        end
      end

      before_should "be called with 3 times correct parameters" do
        UDPSocket.any_instance.expects(:send).times(3).with(instance_of(String), 0, @host, @port).returns(@datagrams)
      end
    end
  end
end
