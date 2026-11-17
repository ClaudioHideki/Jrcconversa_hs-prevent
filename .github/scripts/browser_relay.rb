require 'socket'
raise 'Isolated GitHub runner required' unless ENV['GITHUB_ACTIONS'] == 'true'

listener = TCPServer.new('0.0.0.0', 18_417)
loop do
  client = listener.accept
  Thread.new(client) do |browser|
    upstream = TCPSocket.new('web', 3000)
    pipes = [[browser, upstream], [upstream, browser]].map do |source, target|
      Thread.new do
        IO.copy_stream(source, target)
      rescue IOError, SystemCallError
        nil
      ensure
        target.close_write rescue nil
      end
    end
    pipes.each(&:join)
  rescue IOError, SystemCallError
    nil
  ensure
    browser.close rescue nil
    upstream&.close rescue nil
  end
end
