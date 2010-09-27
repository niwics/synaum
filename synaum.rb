#!/usr/bin/ruby
# author Miroslav Kvasnica - niwi (miradrda@volny.cz), niwi.cz
require 'net/ftp'

class Synaum

  POSSIBLE_PARAMS = ['b', 'd', 'l']

  @error

  @website
  @src_dir
  @params

  @backward
  @deep
  @local

  @ftp
  @ftp_dir
  @username
  @password
  @local_dir
  @modules
  @excluded_modules

  @config_dir
  @dst_dir
  @last_date
  @last_mode
  @sync_file

  def initialize
    # default values
    @local_dir = ''
    @modules = []
    @excluded_modules = []
    @last_date = Time.mktime(1970, 1, 1)
    parse_params
    if !@error
      @src_dir = get_website_dir(@website)
    end
    if !@error
      load_settings
    end
  end



  # parse params
  def parse_params
    param1 = ARGV.shift
    if !param1
      return err 'Nebyl zadán název webu pro synchronizaci.'
    end
    if param1[0,1] == '-'
      @params = param1
      @website = ARGV.shift
      if !@website
        return err 'Nebyl zadán název webu pro synchronizaci.'
      end
    else
      @website = param1
      @params = ARGV.shift
    end
    # check possible params
    if @params != nil
      @params = @params[1..-1] #TODO frozen...
      @params.each_char do |i|
        case i
        when 'b' then @backward = true
        when 'd' then @deep = true
        when 'l' then @local = true
        else
          echo 'Zadán neplatný přepínač: "' + i + '".'
          return err 'Povolené přepínače: "' + POSSIBLE_PARAMS.join('", "') + '".'
        end
      end
    else
      @params = ''
    end
    return true
  end



  # check for the existency of selected website
  def get_website_dir (website)
    if website.index('/') # - was the website name set with a path?
      return website
    else
      module_msg = website != @website ? ' modulu z' : ''
      # try to select the website from the parent folder
      orig_path = Dir.pwd
      Dir.chdir(File.dirname(__FILE__))
      Dir.chdir('..')
      src_dir = Dir.pwd+'/'+website
      Dir.chdir(orig_path)
      if !File.exist?(src_dir)
        # try to load path from the config file
        if @config_dir != nil
          src_dir = @config_dir+'/'+website
        elsif !File.exist?(File.dirname(__FILE__)+"/config")
          @config_dir = false # for future use
          echo 'Nepodařilo se najít složku "'+ src_dir +'" pro provedení synchronizace'+ module_msg +' webu "'+ website +'", ani nebyl nalezen soubor "'+ File.dirname(__FILE__) +'/config", odkud by bylo možné načíst cestu k této složce.'
          return err "Možné zadání cesty ke složce:\n - jako parametr skriptu (např. /work/my-website)\n - v parametru jen název složky např. my-website)\n     - a tato složka musí být umístěna vedle složky se tímto Synaum skriptem\n     - NEBO cesta musí být zadána v souboru config umístěném vedl tohoto Synaum skriptu."
        else
          # load value from config file
          config_file = File.open("config")
          while line = config_file.gets
            line.chomp!
            if line[0,1] != '#'
              @config_dir = line
              src_dir = @config_dir+'/'+website
              break
            end
          end
          if !File.exist?(src_dir)
            return err 'Nebyla nalezena složka "'+ src_dir +'" pro provedení synchronizace'+ module_msg +' webu "' + website + '".'
          end
        end
      end
    end
    return src_dir
  end



  def load_settings
    # load data from the config file
    if !File.exist?(@src_dir+'/synaum')
      return err 'Nebyl nalezen soubor "synaum" potřebný k synchronizaci webu "'+ @website +'".'
    end
    synaum_file = File.open(@src_dir+'/synaum')
    while line = synaum_file.gets
      line.chomp!
      if line[0,1] != '#' and line != ''
        name, value = line.split(' ', 2)
        case name
          when 'ftp' then @ftp = value
          when 'ftp-dir' then @ftp_dir = value
          when 'username' then @username = value
          when 'password' then @password = value
          when 'local-dir' then @local_dir = value
          when 'modules' then @modules = value.split(' ')
          when 'excluded-modules' then @excluded_modules = value.split(' ')
        else
          return err 'Neznámý parametr "'+ name +'" v konfiguračním souboru "'+ @src_dir+'/synaum' +'".'
        end
      end
    end
    
    # info message
    if @local
      msg = 'Lokální'
    elsif @deep
      msg = 'Hluboká lokální'
    else
      msg = 'FTP'
    end
    if @backward
      msg = msg + ' ZPĚTNÁ'
    end
    echo msg+' synchronizace webu "'+ @website +'"...'
    return true
  end


  
  def synchronize
    @src_dir = @src_dir + '/www'
    @dst_dir = @ftp ? @ftp_dir : @local_dir
    check_dst_dir
    if @local or @deep
      synchronize_local
    else
      synchronize_remote
    end
    return true
  end


  def synchronize_local
    # do synchronization
    sync_modules
    sync('/', @src_dir, true)

  end


  def synchronize_remote
    # connect to FTP
    ftp = Net::FTP.new
    ftp.connect(server_name)
    ftp.login(username, password)
    ftp.chdir(directory)
    ftp.getbinaryfile(filename)
    ftp.close
  end


  def check_dst_dir
    # check existency of local folder
    if !@dst_dir
      return err 'Nebyla zadána cesta pro lokální režim (= hodnota "path" v konfiguračním souboru "'+ @src_dir +'/synaum")'
    end
    separ = @local_dir.rindex(File::SEPARATOR) - 1
    local_parent = @local_dir[0..separ]
    if !File.exists?(local_parent)
      return err 'Výstupní složka "'+ local_parent +'" pro synchronizaci na localhostu neexistuje.'
    end
    if !File.writable?(local_parent)
      return err 'Nemáte oprávnění pro zápis do složky "'+ local_parent +'".'
    end

    # check the local directory
    if !File.exist?(@dst_dir)
      Dir.mkdir(@dst_dir, 0775)
    end
  end


  def load_log_file
    # try to load the sync file with the last modification time
    sync_filename = @dst_dir + '/' + 'synaum-log'
    @sync_file = File.new(sync_filename, "r+")
    while line = sync_file.gets
      line.chomp!
      if line[0,1] != '#' and line != ''
        name, value = line.split(' ', 2)
        case name
          when 'last-synchronized' then @last_date = Time.mktime(value)
          when 'mode' then @last_mode = value
        else
          return err 'Neznámý parametr "'+ name +'" v konfiguračním souboru "'+ sync_filename +'".'
        end
      end
    end
  end


  def write_log_file
    # write sync data to the sync file
    now_date = Time.now
    mode = @ftp ? 'ftp' : (@local ? 'local' : 'deep')
    log_msg = <<EOT
# Log synchronizacniho skriptu Synaum pro system Gorazd
# author Miroslav Kvasnica - niwi (miradrda@volny.cz), niwi.cz
last-synchronized #{now_date}
mode #{mode}
EOT
    @sync_file.syswrite(log_msg)
  end


  def sync_modules
    # create module dir if not exists
    if !File.exist?(@dst_dir+'/modules')
      Dir.mkdir(@dst_dir+'/modules', 0775)
    end

    # collect info about modules from other websites
    modules = {}
    @modules.each do |mod|
      add_other_modules(mod, modules)
    end
    # automatically add
    system_dir = get_website_dir('gorazd-system')
    if !system_dir
      return false
    end
    if !modules[system_dir]
      add_other_modules('@gorazd-system', modules)
    end

    # remove excluded modules from hash
    @excluded_modules.each do |mod|
      # get module name and its website
      name, website = mod.split('@')
      if !website
        website = 'gorazd-system'
      end
      src_dir = get_website_dir(website)
      if !src_dir
        return false
      end
      if name == ""
        return err 'Není povoleno zadat "excluded-modules" bez jména modulu (bylo zadáno"'+ mod +'").'
      elsif modules[src_dir].instance_of? Array
        modules[src_dir].delete(name)
      end
    end

    # do sync with modules from other websites
    p modules
    modules.each do |src_dir, modules_array|
      path = src_dir+'/www/modules'
      # => check existency of module folders
      modules_array.each do |mod|
        modpath = path+'/'+mod
        if !File.exist?(modpath)
          return err 'Zadaný modul "'+ modpath +'" neexistuje.'
        elsif !File.directory?(modpath)
          return err 'Zadaný modul "'+ modpath +'" není složka, ale je to soubor.'
        end
      end
      sync('/modules/', src_dir+'/www', false, modules_array)
    end
    # do sync with modules from this website
    sync('/modules/', @src_dir)
  end


  def add_other_modules (mod, modules)
    # get module name and its website
    name, website = mod.split('@')
    if !website
      website = 'gorazd-system'
    end
    src_dir = get_website_dir(website)
    if !src_dir
      return false
    end
    if modules[src_dir] == nil
      modules[src_dir] = []
    end
    if name == ""
      Dir.foreach(src_dir+'/www/modules') do |file|
        if file != '.' and file != '..'
          modules[src_dir] << file
        end
      end
    else
      modules[src_dir] << name
    end
  end


  
  def sync (dir, src_root, is_root = false, allowed_files = nil)
    Dir.foreach(src_root + dir) do |file|
      if file != '.' and file != '..' and (!is_root or file != 'modules') and (!allowed_files or allowed_files.include?(file))
        if @local
          if !File.exist?(@dst_dir+dir+file)
            File.symlink(src_root+dir+file, @dst_dir+dir+file)
          end
        elsif File.file?(src_root+dir+file)
          # check existency and modification time
          if !file_exists(dir+file)
            file_move(dir+file)
          elsif file_modified(dir+file)
            puts 'REMOTE-MODIFIED: '+ dir+file
          elsif File.stat(src_root+dir+file).mtime > @last_date
            file_move(dir+file)
          end
        else
          exists_create dir+file
          sync(dir + file + '/', src_root)
        end
      end
    end
  end


  def file_exists (file)
    return @local ? File.exist?(@dst_dir+file) : false
  end


  def file_modified (file)
    if @local
      return File.stat(@dst_dir+file).mtime > @last_date
    end
    return false
  end


  def file_move (file)
    puts '--copy--'+file
  end


  # Returns true when new dir was created
  def exists_create (dir, src_root)
    if !@local
      return err 'nedodelano exists_create pro FTP'
    end
    
    if File.exist?(@dst_dir + dir)
      echo "DIR existuje "+@dst_dir + dir
    else
      echo "DIR vytvarim... "+@dst_dir + dir
      if @local
        File.symlink(src_root + dir, @dst_dir + dir)
      else
        Dir.mkdir(@dst_dir + dir, 0775)
        return err 'NEIMPLEMENTOVANO - vytvareni dir v exists_create'
      end
    end
  end


  def is_error?
    return @error
  end


  def err (message)
    puts "!!! " + message
    @error = true
    return false
  end


  def echo (message)
    puts "> " + message
  end


  def print_result_message
    if @error
      echo 'Synchronizace nebyla provedena.'
    else
      echo 'Synchronizace proběhla úspěšně'
    end
  end
end



synaum = Synaum.new()
if !synaum.is_error?
  synaum.synchronize
end
synaum.print_result_message