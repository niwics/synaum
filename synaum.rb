#!/usr/bin/ruby
require 'net/ftp'

possible_params = ['l', 'b']

# parse params
param1 = ARGV.shift
if param1[0,1] == '-'
  params = param1
  set_name = ARGV.shift
else
  set_name = param1
  params = ARGV.shift
end
# check possible params
if params != nil
  params = params[1..-1] #TODO frozen...
  params.each_char do |i|
    case i
    when 'l':
      local = true
    when 'b':
      backword = true
    else
      puts 'Zadán neplatný přepínač: ' + i
      puts 'Povolené přepínače: ' + possible_params.join('')
      exit
    end
  end
else
  params = ''
end

# check the config file
if !File.exist?("config")
  puts "Nebyl nalezen soubor \"config\" se synchronizačními sety."
  exit
end

# load values from config file
config_file = File.open("config")
sets = Array.new
while line = config_file.gets
  line.chomp!
  if line[0,1] != '#' and line.index(' ')
    sets.push(line[0,line.index(' ')])
  end
  if line.index(set_name) == 0
    set_values = line.split(' ')
  end
end

# check the module name
if !set_name
  puts "Nebyl zadán název setu pro synchronizaci."
  puts ' Platné sety: "' + sets.join('", "') + '".'
  exit
end
if !sets.include?(set_name)
  puts "Zadán neplatný název setu pro synchronizaci."
  puts ' Platné sety: "' + sets.join('", "') + '".'
  exit
end

# data from the config file
src_path = set_values[1]
ftp_path = set_values[2]
ftp_user = set_values[3]
ftp_pwd = set_values[4]
local_path = set_values[5]

# set modes
if params.index('l')
  local = true
end

if local
  # check existency of local folder
  if !File.exists?(local_path)
    puts 'Výstupní soubor pro synchronizaci na localhostu neexistuje'
    exit
  end

else
  # connect to FTP
  ftp = Net::FTP.new
  ftp.connect(server_name)
  ftp.login(username, password)
  ftp.chdir(directory)
  ftp.getbinaryfile(filename)
  ftp.close
end