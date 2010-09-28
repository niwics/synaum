#!/usr/bin/ruby
# author Miroslav Kvasnica - niwi (miradrda@volny.cz), niwi.cz
require 'net/ftp'
require "fileutils"

class Synaum

  POSSIBLE_PARAMS = ['b', 'd', 'f', 'l', 's']
  DATE_FORMAT = "%d/%m/%Y, %H:%M:%S (%A)"

  @error
  @verbose
  @debug

  @website
  @src_dir
  @params

  @mode
  @backward
  @deep
  @local
  @forced

  @ftp
  @ftp_dir
  @username
  @password
  @local_dir
  @modules
  @excluded_modules

  @output_log
  @config_dir
  @dst_dir
  @last_date
  @last_mode

  @created_dirs
  @created_files

  def initialize
    # default values
    @verbose = true
    @local_dir = ''
    @modules = []
    @excluded_modules = []
    @last_date = Time.mktime(1970, 1, 1)
    @created_dirs = @created_files = 0
    parse_params
    if !@error
      open_output_log
    end
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
        when 'f' then @forced = true
        when 'l' then @local = true
        when 's' then @verbose = false
        else
          err 'Zadán neplatný přepínač: "' + i + '".'
          echo 'Povolené přepínače: "' + POSSIBLE_PARAMS.join('", "') + '".'
          return false
        end
      end
    else
      @params = ''
    end
    @mode = @ftp ? 'ftp' : (@local ? 'local' : 'deep')
    return true
  end


  def open_output_log
    # create dirs if they don't exist
    this_dir = File.dirname(__FILE__)
    now = Time.now().strftime("%d-%m-%Y, %H:%M:%S (%A)")
    cond_mkdir_local(this_dir+'/logs')
    cond_mkdir_local(this_dir+'/logs/'+@website)
    cond_mkdir_local(this_dir+'/logs/'+@website+'/'+@mode)
    @output_log = File.open(this_dir+'/logs/'+@website+'/'+@mode+'/'+now, "w")
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
    check_dst_dir or return false
    load_log_file or return false
    if @ftp
      ftp_connect
    end
    # do synchronization
    sync_modules
    if !@error
      sync('/', @src_dir, true)
    end
    write_log_file
    return true
  end


  def ftp_connect
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
    cond_mkdir_local(@dst_dir)
    return true
  end


  def load_log_file
    # try to load the sync file with the last modification time
    sync_filename = @dst_dir + '/' + 'synaum-log'
    if File.exist?(sync_filename)
      sync_file = File.new(sync_filename, "r+")
      while line = sync_file.gets
        line.chomp!
        if line[0,1] != '#' and line != ''
          name, value = line.split(' ', 2)
          case name
            when 'last-synchronized' then
              arr = value.split(', ')
              vals = arr[0].split('/') + arr[1].split(':')
              @last_date = Time.mktime(vals[2], vals[1], vals[0], vals[3], vals[4], vals[5]);
              last_found = true
            when 'mode' then @last_mode = value
          else
            return err 'Neznámý parametr "'+ name +'" v konfiguračním souboru "'+ sync_filename +'".'
          end
        end
      end

      if last_found
        echo 'Posledni synchronizace proběhla ' + @last_date.strftime(DATE_FORMAT) + '.'
      else
        echo 'Nebyl nalezen soubor s informacemi o poslední synchronizaci.'
      end

      # check modes compatibility
      if @last_mode == 'local' and @deep
        return err 'Minulý režim synchronizace byl "local", tedy s vytvořením symlinků do zdrojové složky. Není proto možné provést synchronizaci "deep". Smažte prosím nejdříve cílovou složku "'+ @dst_dir +'" nebo její obsah.'
      elsif @last_mode == 'deep' and @local
        return err 'Minulý režim synchronizace byl "deep", tedy s fyzickým kopírováním souborů do cílové složky. Není proto možné provést synchronizaci "local", která pracuje se symliky. Smažte prosím nejdříve cílovou složku "'+ @dst_dir +'" nebo její obsah.'
      end
    end
    return true
  end


  def write_log_file
    if @debug
      echo 'Zapisuji do výstupního logu...'
    end
    # write sync data to the sync file
    now_date = Time.now.strftime(DATE_FORMAT)
    log_msg = <<EOT
# Log synchronizacniho skriptu Synaum pro system Gorazd
# author Miroslav Kvasnica - niwi (miradrda@volny.cz), niwi.cz
last-synchronized #{now_date}
mode #{@mode}
EOT
    sync_file = File.new(@dst_dir + '/' + 'synaum-log', "w")
    sync_file.syswrite(log_msg)
  end


  def sync_modules
    # create module dir if not exists
    if !File.exist?(@dst_dir+'/modules')
      mkdir(@dst_dir+'/modules', 0775)
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

    if @debug
      echo 'Synchronizuji moduly z ostatních webů: '
      modules.each do |src_dir, modules_array|
        puts '   z ' + src_dir + ': ' + modules_array.join(', ')
      end
    end
    # do sync with modules from other websites
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
      if file != '.' and file != '..' and file !~ /~$/ and (!is_root or file != 'modules') and (!allowed_files or allowed_files.include?(file))
        exists = file_exists?(dir+file)
        if @local
          if !exists
            file_move(src_root+dir+file, @dst_dir+dir+file)
          end
        elsif is_dir?(src_root+dir+file)
          if !exists and !@backward
            mkdir(@dst_dir+dir+file)
          end
          sync(dir + file + '/', src_root)
        else
          if exists and !@backward
            # src file modification time
            src_modified = File.stat(src_root+dir+file).mtime > @last_date
          end
          if exists or (src_modified and !@forced)
            dst_modified = dst_modified?(dir+file)  # dst file modification time
          end
          if !@backward and (!exists or (src_modified and (!dst_modified or @forced)))
            file_move(src_root+dir+file, @dst_dir+dir+file)
          end
          if dst_modified and (@verbose or src_modified)
            puts 'REMOTE-MODIFIED: '+ dir+file
          end
        end
      end
    end
  end


  def is_dir? (dir)
    return @ftp ? false : File.directory?(dir)
  end


  def file_exists? (file)
    return @ftp ? false : File.exist?(@dst_dir+file)
  end


  def dst_modified? (file)
    if @local or @deep
      return File.stat(@dst_dir+file).mtime > @last_date
    end
    return false
  end


  def file_move (src, dst)
    if @ftp
      if @verbose
        puts 'Kopíruji soubor "'+ dst +'".'
      end
      puts 'NEIMP move'
    elsif @local
      if @verbose
        puts 'Vytvářím symlink na soubor "'+ dst +'".'
      end
      File.symlink(src, dst)
    else
      if @verbose
        puts 'Kopíruji soubor "'+ dst +'".'
      end
      FileUtils.cp(src, dst)
    end
    @created_files += 1
  end


  # Returns true when new dir was created
  def mkdir (dir)
    if @local
      return err 'Funkci "Synaum::mkdir" nelze použít v režimu "local".'
    end

    if @verbose
      puts 'Vytvářím složku "'+ dir +'".'
    end
    
    if @deep
      Dir.mkdir(dir, 0775)
    else
      err 'NEIMPL mkdir'
    end
    @created_dirs += 1
  end


  def cond_mkdir_local (dir)
    if !File.exist?(dir)
      Dir.mkdir(dir, 0775)
    end
  end



  def is_error?
    return @error
  end


  def err (message)
    real_echo("!!! " + message, false)
    @error = true
    return false
  end


  def echo (message, formatted = true)
    if @verbose
      real_echo(message, formatted)
    else
      log_msg(msg)
    end
  end


  def real_echo (message, formatted = true)
    msg = (formatted ? '> ' :'') + message
    puts msg
    log_msg(msg)
  end


  def log_msg (msg)
    if @output_log
      @output_log.syswrite(msg+"\n")
    end
  end


  def print_result_message
    nochange = ''
    if @created_files + @created_dirs > 0
      echo "Bylo synchronizováno #{@created_files} souborů a vytvořeno #{@created_dirs} složek."
    else
      nochange = ' Nebyly provedeny žádné změny.'
    end
    if @error
      err 'Synchronizace nebyla provedena!'
    else
      echo 'Synchronizace proběhla úspěšně.' + nochange
    end
  end
end



synaum = Synaum.new()
if !synaum.is_error?
  synaum.synchronize
end
synaum.print_result_message