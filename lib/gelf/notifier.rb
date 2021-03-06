module GELF
  # Graylog2 notifier.
  class Notifier
    @last_chunk_id = 0
    class << self
      attr_accessor :last_chunk_id
    end

    attr_accessor :host, :port, :default_options, :enabled
    attr_reader :max_chunk_size, :level

    # +host+ and +port+ are host/ip and port of graylog2-server.
    # +max_size+ is passed to max_chunk_size=.
    # +default_options+ is used in notify!
    def initialize(host = 'localhost', port = 12201, max_size = 'WAN', default_options = {})
      @enabled = true

      self.level = GELF::DEBUG

      self.host, self.port, self.max_chunk_size = host, port, max_size

      self.default_options = default_options
      self.default_options['version'] = SPEC_VERSION
      self.default_options['host'] ||= Socket.gethostname
      self.default_options['level'] ||= GELF::UNKNOWN
      self.default_options['facility'] ||= 'gelf-rb'

      @sender = RubyUdpSender.new(host, port)
    end

    # +size+ may be a number of bytes, 'WAN' (1420 bytes) or 'LAN' (8154).
    # Default (safe) value is 'WAN'.
    def max_chunk_size=(size)
      size_s = size.to_s.downcase
      if size_s == 'wan'
        @max_chunk_size = 1420
      elsif size_s == 'lan'
        @max_chunk_size = 8154
      else
        @max_chunk_size = size.to_int
      end
    end

    def level=(new_level)
      @level = if new_level.is_a?(Fixnum)
                 new_level
               else
                 GELF.const_get(new_level.to_s.upcase)
               end
    end

    def disable
      @enabled = false
    end

    def enable
      @enabled = true
    end

    # Same as notify!, but rescues all exceptions (including +ArgumentError+)
    # and sends them instead.
    def notify(*args)
      notify_with_level(nil, *args)
    end

    # Sends message to Graylog2 server.
    # +args+ can be:
    # - hash-like object (any object which responds to +to_hash+, including +Hash+ instance):
    #    notify!(:short_message => 'All your rebase are belong to us', :user => 'AlekSi')
    # - exception with optional hash-like object:
    #    notify!(SecurityError.new('ALARM!'), :trespasser => 'AlekSi')
    # - string-like object (anything which responds to +to_s+) with optional hash-like object:
    #    notify!('Plain olde text message', :scribe => 'AlekSi')
    # Resulted fields are merged with +default_options+, the latter will never overwrite the former.
    def notify!(*args)
      notify_with_level!(nil, *args)
    end

    GELF::Levels.constants.each do |const|
      class_eval <<-EOT, __FILE__, __LINE__ + 1
        def #{const.downcase}(*args)                          # def debug(*args)
          notify_with_level(GELF::#{const}, *args)            #   notify_with_level(GELF::DEBUG, *args)
        end                                                   # end
      EOT
    end

  private
    def notify_with_level(message_level, *args)
      notify_with_level!(message_level, *args)
    rescue Exception => exception
      notify_with_level!(GELF::UNKNOWN, exception)
    end

    def notify_with_level!(message_level, *args)
      return unless @enabled
      extract_hash(*args)
      @hash['level'] = message_level unless message_level.nil?
      if @hash['level'] >= level
        @sender.send_datagrams(datagrams_from_hash)
      end
    end

    def extract_hash(object = nil, args = {})
      primary_data = if object.respond_to?(:to_hash)
                       object.to_hash
                     elsif object.is_a?(Exception)
                       args['level'] ||= GELF::ERROR
                       self.class.extract_hash_from_exception(object)
                     else
                       args['level'] ||= GELF::INFO
                       { 'short_message' => object.to_s }
                     end

      @hash = default_options.merge(args.merge(primary_data))
      stringify_hash_keys
      convert_hoptoad_keys_to_graylog2
      set_file_and_line
      set_timestamp
      check_presence_of_mandatory_attributes
      @hash
    end

    def self.extract_hash_from_exception(exception)
      bt = exception.backtrace || ["Backtrace is not available."]
      { 'short_message' => "#{exception.class}: #{exception.message}", 'full_message' => "Backtrace:\n" + bt.join("\n") }
    end

    # Converts Hoptoad-specific keys in +@hash+ to Graylog2-specific.
    def convert_hoptoad_keys_to_graylog2
      if @hash['short_message'].to_s.empty?
        if @hash.has_key?('error_class') && @hash.has_key?('error_message')
          @hash['short_message'] = @hash.delete('error_class') + ': ' + @hash.delete('error_message')
        end
      end
    end

    CALLER_REGEXP = /^(.*):(\d+).*/
    LIB_GELF_PATTERN = File.join('lib', 'gelf')

    def set_file_and_line
      stack = caller
      begin
        frame = stack.shift
      end while frame.include?(LIB_GELF_PATTERN)
      match = CALLER_REGEXP.match(frame)
      @hash['file'] = match[1] if @hash['file'] == nil
      @hash['line'] = match[2].to_i if @hash['line'] == nil
    end

    def set_timestamp
      @hash['timestamp'] = Time.now.utc.to_f
    end

    def check_presence_of_mandatory_attributes
      %w(version short_message host).each do |attribute|
        if @hash[attribute].to_s.empty?
          raise ArgumentError.new("#{attribute} is missing. Options version, short_message and host must be set.")
        end
      end
    end

    def datagrams_from_hash
      data = serialize_hash
      datagrams = []

      # Maximum total size is 8192 byte for UDP datagram. Split to chunks if bigger. (GELFv2 supports chunking)
      if data.count > @max_chunk_size
        id = self.class.last_chunk_id += 1
        msg_id = Digest::MD5.digest("#{Time.now.to_f}-#{id}")[0, 8]
        num, count = 0, (data.count.to_f / @max_chunk_size).ceil
        data.each_slice(@max_chunk_size) do |slice|
          datagrams << "\x1e\x0f" + msg_id + [num, count, *slice].pack('C*')
          num += 1
        end
      else
        datagrams << data.to_a.pack('C*')
      end

      datagrams
    end

    def serialize_hash
      raise ArgumentError.new("Hash is empty.") if @hash.nil? || @hash.empty?

      @hash['level'] = GELF::LEVELS_MAPPING[@hash['level']]

      Zlib::Deflate.deflate(@hash.to_json).bytes
    end

    def stringify_hash_keys
      @hash.keys.each do |key|
        value, key_s = @hash.delete(key), key.to_s
        @hash[key_s] = value
      end
    end
  end
end
