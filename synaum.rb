#!/usr/bin/ruby
require 'net/ftp'

# get the server, username and password
servers = {"admin..spjf.cz" => "admin_spjf ",
  "dlouhodobka.cz" => "dlouhodobkacz",
  "beta.spjf.cz" => "tester"}
servers.each do |i|
  #print i
end
server_name = ARGV.shift
username = servers[server_name]
if !username
  puts "Nebyl zadán platný server pro synchronizaci."
  puts " Platné servery: " + servers.keys.join(", ") + "."
  exit
end
print "Zadejte heslo pro připojení k FTP: "
password = gets
password.chomp!

# connect to FTP
ftp = Net::FTP.new
ftp.connect(server_name)
ftp.login(username, password)
ftp.chdir(directory)
ftp.getbinaryfile(filename)
ftp.close