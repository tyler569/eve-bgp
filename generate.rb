#!/usr/bin/env ruby

require 'erb'
require 'netaddr'
require 'optparse'
require 'sqlite3'
require 'yaml'

options = {}

OptionParser.new do |opts|
  opts.on('--su', 'Attempt to load DNS zonefiles into named') { options[:su] = true }
  opts.on('--dump', 'Dump state') { options[:dump] = true }
end.parse!

DNS_HEADER = <<EOF
$TTL	10
@	IN	SOA	localhost. root.localhost. (
            1		; Serial
       604800		; Refresh
        86400		; Retry
      2419200		; Expire
        86400 )	; Negative Cache TTL
;
@	IN	NS	localhost.
EOF

db = SQLite3::Database.new 'sde.sqlite'

jumps = db.execute <<-EOQ
SELECT f.solarSystemName, t.solarSystemName
FROM mapSolarSystemJumps j
  INNER JOIN mapSolarSystems f
    ON j.fromSolarSystemID = f.solarSystemID
  INNER JOIN mapSolarSystems t
    ON j.toSolarSystemID = t.solarSystemID
WHERE f.solarSystemName > t.solarSystemName;
EOQ

all_systems = jumps.flatten.uniq

systems = {}
system_net = NetAddr::IPv4Net.parse("10.32.1.0/24")
system_as = 100

class System
  attr_reader :name, :host, :as
  attr_accessor :peers

  @@template = File.read("bird.conf.erb")

  def initialize(name, net, as)
    @name = name
    @net = net.to_s
    @host = net.nth(1).to_s
    @peers = []
    @as = as
  end

  def render
    ERB.new(@@template).result(binding)
  end
end

all_systems.each do |system|
  system = system.gsub(' ', '-')[..14]
  systems[system] = System.new(system, system_net, system_as)
  system_net = system_net.next_sib
  system_as += 1
end

jumps.each do |a, b|
  a = a.gsub(' ', '-')[..14]
  b = b.gsub(' ', '-')[..14]
  raise if systems[b].peers.map { |p| p[:name] }.include? a
  systems[a].peers << {
    name: b,
    net: system_net.to_s,
    local_host: system_net.nth(1).to_s,
    remote_host: system_net.nth(2).to_s,
    as: systems[b].as,
    primary: true
  }
  systems[b].peers << {
    name: a,
    net: system_net.to_s,
    local_host: system_net.nth(2).to_s,
    remote_host: system_net.nth(1).to_s,
    as: systems[a].as,
    primary: false
  }

  system_net = system_net.next_sib
end

all_systems = []
jumps = []

`rm -rf configs`
Dir.mkdir('configs')
systems.each do |name, system|
  File.open("configs/#{name}.conf", 'w+') do |f|
    f.write(system.render)
  end
end

File.open('configs/eve.zone', 'w+') do |f|
  f.puts DNS_HEADER

  systems.each do |name, system|
    f.puts <<~EOF
    #{name.ljust 15} IN   A   #{system.host}
    EOF
  end
end

File.open('configs/10.zone', 'w+') do |f|
  f.puts DNS_HEADER

  systems.each do |name, system|
    ptr = system.host.split('.').drop(1).reverse.join('.')

    f.puts <<~EOF
    #{ptr.ljust 15} IN   PTR   #{name}.eve.
    EOF
  end
end

File.open('netns.bash', 'w+') do |f|
  f.puts <<~EOF
  function xrun() {
    $@
    if [[ $? -ne 0 ]]; then
      echo "^ $@"
    fi
  }
  EOF
  f.puts "set -x"
  f.puts " ip -all netns delete"
  systems.each do |name, system|
    f.puts(" ip netns add #{name}")
    f.puts(" ip netns exec #{name} ip addr add #{system.host}/24 dev lo")
    f.puts(" ip netns exec #{name} ip link set lo up")
  end
  systems.each do |name, system|
    system.peers.each do |peer|
      next unless peer[:primary]
      f.puts(" ip link add #{name} netns #{peer[:name]} type veth peer #{peer[:name]} netns #{name}")
    end
  end
  systems.each do |name, system|
    system.peers.each do |peer|
      f.puts(" ip netns exec #{name} ip addr add #{peer[:local_host]}/24 dev #{peer[:name]}")
    end
  end
  systems.each do |name, system|
    system.peers.each do |peer|
      f.puts(" ip netns exec #{name} ip link set #{peer[:name]} up")
    end
  end
end

File.open('start.bash', 'w+') do |f|
  f.puts "set -x"
  f.puts "mkdir -p run"
  systems.each do |name, system|
    # next unless name =~ /[a-z]/
    f.puts("ip netns exec #{name} bird -c configs/#{name}.conf -s run/#{name}")
  end
end


if options[:su]
  # This is based on my Ubuntu 20.04 machine, I needed to edit some
  # systemd-resolved settings to get named to be used for local resolution, 
  # I also needed to edit /etc/bind/named.conf.local to add
  # zone "eve" {
  #   type master;
  #   file "/etc/bind/eve.zone";
  # };
  # zone "10.in-addr.arpa" {
  #   type master;
  #   file "/etc/bind/10.zone";
  # };
  `sudo cp configs/eve.zone /etc/bind`
  `sudo cp configs/10.zone /etc/bind`
  `sudo systemctl reload named`
end

if options[:dump]
  puts YAML.dump systems
end
