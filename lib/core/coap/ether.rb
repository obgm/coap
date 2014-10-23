module CoRE
  module CoAP
    # Socket abstraction.
    class Ether
      DEFAULT_RECV_TIMEOUT = 2

      attr_accessor :max_retransmit, :recv_timeout
      attr_reader :address_family, :socket

      def initialize(options = {})
        @max_retransmit   = options[:max_retransmit] || 4
        @recv_timeout     = options[:recv_timeout]   || DEFAULT_RECV_TIMEOUT
        @socket           = options[:socket]

        @retransmit       = if options[:retransmit].nil?
                              true
                            else
                              !!options[:retransmit]
                            end

        if @socket
          @socket_class   = @socket.class
          @address_family = @socket.addr.first
        else
          @socket_class   = options[:socket_class]   || Celluloid::IO::UDPSocket
          @address_family = options[:address_family] || Socket::AF_INET6
          @socket         = @socket_class.new(@address_family)
        end

        @socket
      end

      # Receive from socket and return parsed CoAP message. (ACK is sent on CON
      # messages.)
      def receive(options = {})
        retry_count = options[:retry_count] || 0
        timeout = (options[:timeout] || @recv_timeout) ** (retry_count + 1)

        data = Timeout.timeout(timeout) do
          @socket.recvfrom(1024)
        end

        answer = CoAP.parse(data[0].force_encoding('BINARY'))

        if answer.tt == :con
          message = Message.new(:ack, 0, answer.mid, nil,
            {token: answer.options[:token]})

          send(message, data[1][3])
        end

        answer
      end

      # Send +message+.
      def send(message, host, port = CoAP::PORT)
        message = message.to_wire if message.respond_to?(:to_wire)
        # In MRI and Rubinius, the Socket::MSG_DONTWAIT option is 64.
        # It is not defined by JRuby.
        # TODO Is it really necessary?
        @socket.send(message, 64, host, port)
      end

      # Send +message+ (retransmit if necessary) and wait for answer. Returns
      # answer.
      def request(message, host, port = CoAP::PORT)
        retry_count = 0

        begin
          send(message, host, port)
          response = receive(retry_count: retry_count)
        rescue Timeout::Error
          raise unless @retransmit

          retry_count += 1

          if retry_count > @max_retransmit
            raise "Maximum retransmission count of #{@max_retransmit} reached."
          end

          retry
        end

        check_mid(message, response)

        response = receive(timeout: 10) if seperate?(response)

        check_token(message, response)

        response
      end

      private

      # Check whether response mid mismatches.
      def check_mid(request, response)
        raise 'Wrong message id.' if request.mid != response.mid
      end

      # Check whether response token mismatches.
      def check_token(request, response)
        if request.options[:token] != response.options[:token]
          raise 'Wrong token.'
        end
      end

      # Check if answer is seperated.
      def seperate?(response)
        r = response
        r.tt == :ack && r.payload.empty? && r.mcode == [0, 0]
      end

      class << self
        # Return Ether instance with socket matching address family.
        def from_host(host, options = {})
          if IPAddr.new(host).ipv6? 
            new(options)
          else
            new(options.merge(address_family: Socket::AF_INET))
          end
        # MRI throws IPAddr::InvalidAddressError, JRuby an ArgumentError
        rescue StandardError
          host = Resolver.address(host)
          retry
        end

        # Instanciate matching Ether and send message.
        def send(*args)
          invoke(:send, *args)
        end

        # Instanciate matching Ether and perform request.
        def request(*args)
          invoke(:request, *args)
        end

        private

        # Instanciate matching Ether and invoke +method+ on instance.
        def invoke(method, *args)
          options = {}
          options = args.pop if args.last.is_a? Hash

          if options[:socket]
            ether = Ether.new(options)
          else
            ether = from_host(args[1], options)
          end

          [ether, ether.__send__(method, *args)]
        end
      end
    end
  end
end
