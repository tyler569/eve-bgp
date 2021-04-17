# EVE BGP Universe

Inspired by https://blog.benjojo.co.uk/post/eve-online-bgp-internet

1. Get the [Static Data Export](https://www.fuzzwork.co.uk/dump/) in
   SQLite format, extract it to this directory as `sde.sqlite`
1. Run `generate.rb` to generate the configurations
1. Run `netns.bash` to create the network namespaces and interfaces
1. Run `start.bash` to boot the routers in each system

Each system is a network namespace, you can run commands in them with
`ip netns exec System-Name command`.

`generate.rb` also creates forward and reverse DNS zone files, at
`configs/eve.zone` and `configs/10.zone`. Load these into your local DNS
resolver to be able to access the systems by name (`ping Jita.eve`).

Running ~5000 copies of BIRD all trying to talk to each other over the
network at the same time is fairly load intensive, I wouldn't run this
on your main computer - it nearly crashed mine.

`generate.rb --dump` dumps the generated Universe state, system
addresses, and link addresses in YAML format for debugging.
