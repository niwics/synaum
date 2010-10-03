#!/usr/bin/ruby
# author Miroslav Kvasnica - niwi (miradrda@volny.cz), niwi.cz
require 'net/ftp'
require 'net/http'
require "fileutils"

class Synaum

  POSSIBLE_PARAMS = ['d', 'f', 'l', 's', 't']
  DATE_FORMAT = "%d/%m/%Y, %H:%M:%S (%A)"
  SYNC_FILENAME = 'synaum-log'
  SYNC_FILES_LIST_NAME = 'synaum-list.txt'

  @error
  @verbose
  @debug

  @website
  @src_dir
  @params

  @mode
  @deep
  @local
  @simulation
  @forced

  # FTP connection (Net::FTP) connector
  # - also used for bool testing - so it's pre-inited
  #   to the true in parse_params function
  @ftp
  @ftp_servername
  @ftp_dir
  @username
  @password
  @http_servername
  @local_dir
  @modules
  @excluded_modules

  @output_log
  @config_dir
  @dst_dir
  @last_date
  @last_mode
  @old_remote_modifieds
  @new_remote_modifieds

  @module_names
  @ftp_remote_list
  @created_dirs
  @created_files

  def initialize
    # default values
    @ftp_mode = true
    @ftp_dir = ''
    @local_dir = ''
    @modules = []
    @excluded_modules = []
    @old_remote_modifieds = []
    @new_remote_modifieds = []
    @module_names = []
    @ftp_remote_list = {}
    @verbose = true
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
      @params = @params[1..-1] # is frozen...
      @params.each_char do |i|
        case i
        when 'd' then @deep = true
        when 'f' then @forced = true
        when 'l' then @local = true
        when 's' then @simulation = true
        when 't' then @verbose = false
        else
          err 'Zadán neplatný přepínač: "' + i + '".'
          echo 'Povolené přepínače: "' + POSSIBLE_PARAMS.join('", "') + '".'
          return false
        end
      end
    else
      @params = ''
    end

    # pre-init ftp value (later will be really inited in ftp_connect function)
    @ftp = (!@local and !@deep)
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
          err 'Nepodařilo se najít složku "'+ src_dir +'" pro provedení synchronizace'+ module_msg +' webu "'+ website +'", ani nebyl nalezen soubor "'+ File.dirname(__FILE__) +'/config", odkud by bylo možné načíst cestu k této složce.'
          return err "Možné zadání cesty ke složce:\n - jako parametr skriptu (např. /work/my-website)\n - v parametru jen název složky např. my-website)\n     - a tato složka musí být umístěna vedle složky se tímto Synaum skriptem\n     - NEBO cesta musí být zadána v souboru config umístěném vedl tohoto Synaum skriptu."
        else
          # load value from config file
          config_file = File.open(File.dirname(__FILE__)+"/config")
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
        if !value
          return err 'Nebyla zadána hodnota u parametru "'+ name +'" v konfiguračním souboru "'+ @src_dir+'/synaum' +'".'
        end
        case name
          when 'ftp' then @ftp_servername = value
          when 'ftp-dir' then @ftp_dir = value[0..1]=='/' ? value : '/'+value
          when 'username' then @username = value
          when 'password' then @password = value
          when 'http-servername' then @http_servername = value
          when 'local-dir' then @local_dir = value
          when 'modules' then @modules = value.split(' ')
          when 'excluded-modules' then @excluded_modules = value.split(' ')
        else
          return err 'Neznámý parametr "'+ name +'" v konfiguračním souboru "'+ @src_dir+'/synaum' +'".'
        end
      end
    end

    # check params for FTP
    if !@local and !@deep
      if !@ftp_servername
        return err 'Nebyl zadán FTP server pro synchronizaci. Pokud chcete pracovat pouze s lokálními soubory, použijte přepínač -d nebo -l (viz nápověda - "synaum help")'
      elsif !@username
        return err 'Nebylo zadáno uživatelské jméno pro připojení k FTP serveru.'
      end
    end

    if !@http_servername
      @http_servername = @ftp_servername
    end
    
    # info message
    if @local
      msg = 'Lokální'
    elsif @deep
      msg = 'Hluboká lokální'
    else
      msg = 'FTP'
    end
    if @simulation
      msg += ' CVIČNÁ'
    end
    real_echo msg+' synchronizace webu "'+ @website +'"...'
    return true
  end


  
  def synchronize
    @src_dir = @src_dir + '/www'
    if @ftp
      @dst_dir = @ftp_dir
    else
      @dst_dir = @local_dir
      check_dst_dir or return false
    end
    
    if @ftp
      ftp_prepare or return false
    end
    load_sync_file or return false
    # do synchronization
    #sync_modules
    if !@error
      sync('/', @src_dir)
    end
    write_log_file
    return true
  end


  def ftp_prepare
    # connect to FTP
    @ftp = Net::FTP.new
    echo("Připojování k FTP serveru \"#{@ftp_servername}\"...", false, false)
    begin
      @ftp.connect(@ftp_servername)
    rescue
      return err "\n!!! Nepodařilo se připojit k FTP serveru \"#{@ftp_servername}\"."
    end
    begin
      @ftp.login(@username, @password)
    rescue
      return err "\n!!! Nepodařilo se přihlásit k FTP \"#{@ftp_servername}\" s uživatelským jménem \"#{@username}\". Zkontrolujte v konfiguračním souboru \"#{@src_dir}/synaum\" nastavení FTP serveru, uživatelského jména a hesla."
    end
    echo(' úspěšně připojeno.')
    
    if !dst_file_exist?(@ftp_dir, false)
      return err "Na serveru nebyla nalezena zadaná kořenová složka \"#{@ftp_dir}\". Zkontrolujte existenci této složky a její oprávnění zápisu. Cestu k ní je možné upravit v konfiguračním souboru \"#{@src_dir}/synaum\"."
    end

    # call remote ajax PHP script and load directories list
    ajax_name = '/ajax/system/synaum-list-files.php'
    begin
      http = Net::HTTP.new(@http_servername)
    rescue
      return err "Nepodařilo se vytvořit HTTP připojení se serverem #{@http_servername}. Zkontrolujte adresu serveru (automaticky je shodná s FTP adresou, ale můžete ji také upravit v konfiguračním souboru \"#{@src_dir}/synaum\"."
    end
    begin
      res = http.get(ajax_name)
    rescue
      return err "Nepodařilo se načíst AJAXový PHP skript \"#{@http_servername}#{ajax_name}\"."
    end
    if res.body != '1'
      return err "Neúspěšné volání AJAXového PHP skriptu - skript \"#{@http_servername}#{ajax_name}\" nevrátil hodnotu \"1\"."
    end
    if !dst_file_exist?(SYNC_FILES_LIST_NAME)
      return err "Nepodařilo se najít vzdálený soubor \"#{@dst_dir}/#{SYNC_FILES_LIST_NAME}\"."
    end
    # load data
    @ftp.getbinaryfile(@dst_dir+'/'+SYNC_FILES_LIST_NAME, '/tmp/'+SYNC_FILES_LIST_NAME)
    lists_file = File.new('/tmp/' + SYNC_FILES_LIST_NAME, "r")
    while line = lists_file.gets
      line.chomp!
      if line[0,1] != '#' and line != ''
        name, value = line.split("\t", 2)
        @ftp_remote_list[@ftp_dir+name] = value
      end
    end
    File.delete('/tmp/'+SYNC_FILES_LIST_NAME)
    return true
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


  def load_sync_file
    # try to load the sync file with the last modification time
    if dst_file_exist?(SYNC_FILENAME)
      if @ftp
        # download the remote file
        @ftp.getbinaryfile(@dst_dir+'/'+SYNC_FILENAME, '/tmp/'+SYNC_FILENAME)
      end
      sync_file = File.new((@ftp ? '/tmp' : @dst_dir) + '/' + SYNC_FILENAME, "r")
      while line = sync_file.gets
        line.chomp!
        if line[0,1] != '#' and line != ''
          name, value = line.split(' ', 2)
          case name
            when 'last-synchronized' then
              arr = value.split(', ')
              vals = arr[0].split('/') + arr[1].split(':')
              @last_date = Time.mktime(vals[2], vals[1], vals[0], vals[3], vals[4], vals[5])
              last_found = true
            when 'mode' then @last_mode = value
            when 'REMOTE_MODIFIED' then rems_allowed = true
          else
            if rems_allowed and line[0,1] == '/'
              @old_remote_modifieds << line
            else
              return err 'Neznámý parametr "'+ name +'" v konfiguračním souboru "'+ @dst_dir + '/' + SYNC_FILENAME + '".'
            end
          end
        end
      end
      # delete tmp file
      if @ftp
        File.delete('/tmp/'+SYNC_FILENAME)
      end
      real_echo 'Poslední synchronizace proběhla ' + @last_date.strftime(DATE_FORMAT) + '.'

      # check modes compatibility
      if @last_mode == 'local' and @deep
        return err 'Minulý režim synchronizace byl "local", tedy s vytvořením symlinků do zdrojové složky. Není proto možné provést synchronizaci "deep". Smažte prosím nejdříve cílovou složku "'+ @dst_dir +'" nebo její obsah.'
      elsif @last_mode == 'deep' and @local
        return err 'Minulý režim synchronizace byl "deep", tedy s fyzickým kopírováním souborů do cílové složky. Není proto možné provést synchronizaci "local", která pracuje se symliky. Smažte prosím nejdříve cílovou složku "'+ @dst_dir +'" nebo její obsah.'
      end
    else
      real_echo 'Nebyl nalezen soubor s informacemi o poslední synchronizaci.'
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
    if @new_remote_modifieds.count > 0
      rems= @new_remote_modifieds.join("\n")
      log_msg += <<EOT

REMOTE_MODIFIED files in last synchronization:
#---------------------------------------------
#{rems}
EOT
    end

    # write file
    filename = (@ftp ? '/tmp' : @dst_dir) + '/' + SYNC_FILENAME
    sync_file = File.new(filename, "w")
    sync_file.syswrite(log_msg)
    if @ftp
      # upload the temp file
      file_move(filename, @dst_dir + '/' + SYNC_FILENAME, true)
      # delete tmp file
      if @ftp
        File.delete('/tmp/'+SYNC_FILENAME)
      end
    end
  end


  def sync_modules
    # create module dir if not exists
    if !dst_file_exist?('modules')
      if @simulation
        return true
      end
      mkdir(@dst_dir+'/modules')
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
    end
    modules.each do |src_dir, modules_array|
      @module_names += modules_array
      if @debug
        echo '   z ' + src_dir + ': ' + modules_array.join(', '), false
      end
    end
    # do sync with the system root folder (except its "modules", of course)
    sync('/', system_dir+'/www')
    # do sync with modules from other websites
    modules.each do |src_dir, modules_array|
      path = src_dir+'/www/modules'
      # check existency of module folders
      modules_array.each do |mod|
        modpath = path+'/'+mod
        if !File.exist?(modpath)
          return err 'Zadaný modul "'+ modpath +'" neexistuje.'
        elsif !File.directory?(modpath)
          return err 'Zadaný modul "'+ modpath +'" není složka, ale je to soubor.'
        end
      end
      sync('/modules/', src_dir+'/www', modules_array)
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


  
  def sync (dir, src_root, allowed_files = nil)
    if @debug
      puts '...SYNC: ' + src_root + dir
    end
    files = Dir.entries(src_root + dir)
    remote_files = list_remote_files(@dst_dir + dir)
    # check additional files on the target direcory
    if src_root == @src_dir or (dir != '/modules/' and dir != '/')
      additional_files = remote_files.keys - files
      if dir == '/modules/'
        additional_files -= @module_names
      elsif dir == '/'
        system_dir = get_website_dir('gorazd-system')
        additional_files -= Dir.entries(system_dir+'/www')
        additional_files.delete('synaum-log')
        additional_files.delete('synaum-list.txt')
      end
      additional_files.each do |f|
        echo 'SOURCE_MISSING: '+dir+f
      end
    end
    files.each do |file|
      if file != '.' and file != '..' and file !~ /~$/ and (dir != '/' or (file != 'modules' and file != 'config-local.php')) and (!allowed_files or allowed_files.include?(file))
        exists = remote_files.key?(file)
        if @debug
          echo '...kontrola souboru "' + src_root + dir + '/' + file+'"...'
        end
        if @local
          if !exists
            file_move(src_root+dir+file, @dst_dir+dir+file)
          end
        elsif File.directory?(src_root+dir+file)
          if !exists and !@simulation
            mkdir(@dst_dir+dir+file)
          end
          sync(dir + file + '/', src_root)
        else
          if exists and !@simulation
            # src file modification time
            src_modified = File.stat(src_root+dir+file).mtime > @last_date
          end
          if exists or (src_modified and !@forced)
            dst_modified = dst_modified?(dir+file)  # dst file modification time
          end
          if dst_modified
            if @verbose or src_modified
              echo 'REMOTE-MODIFIED: '+dir+file
            end
            if !@forced
              @new_remote_modifieds << dir+file
            end
          end
          if !@simulation and (!exists or (src_modified and (!dst_modified or @forced)))
            file_move(src_root+dir+file, @dst_dir+dir+file)
          end
        end
      end
    end
  end


  def list_remote_files (path)
    list = {}
    if @ftp
      begin
        # split appropriate fiels string
        files = @ftp_remote_list[path].split("\t")
        files.each do |line|
          file, date = line.split("//")
          list[file] = date
        end
#      rescue
#        err "Chyba při procházení stromem na serveru - \"#{path}\" není složka!"
      end
    else
      if File.exist?(path)
        list = Hash[Dir.entries(path).map {|x| [x, nil]}]
      end
    end
    #p list
    return list
  end


  def dst_file_exist? (path, append_path_prefix = true)
    path = (append_path_prefix ? @dst_dir+'/' : '') + path
    if @ftp
      re = Regexp.new('\s' + File.basename(path) + '$')
      list = @ftp.list(File.dirname(path))
      list.each do |line|
        if line =~ re
          return true
        end
      end
    else
      return File.exist?(path)
    end
    return false
  end


  def dst_modified? (file)
    if @old_remote_modifieds.include?(file)
      return true
    end
    if @local or @deep
      return File.stat(@dst_dir+file).mtime > @last_date
    end
    return false
  end


  def file_move (src, dst, control_file = false)
    if !control_file or @debud
      echo (@ftp ? 'Kopíruji' : 'Vytvářím symlink na') + ' soubor "'+ src +'".'
    end
    if @ftp
      @ftp.putbinaryfile(src, dst)
    elsif @local
      File.symlink(src, dst)
    else
      FileUtils.cp(src, dst)
    end
    if !control_file
      @created_files += 1
    end
  end


  # Returns true when new dir was created
  def mkdir (dir)
    echo 'Vytvářím složku "'+ dir +'".'
    
    if @ftp
      @ftp.mkdir(dir)
    else
      Dir.mkdir(dir, 0775)
    end
    @created_dirs += 1
  end


  def cond_mkdir_local (dir)
    if !File.exist?(dir)
      echo 'Vytvářím lokální složku "'+ dir +'".'
      Dir.mkdir(dir, 0775)
    end
  end


#  def ftp_file_exist? (filename)
#    if dir
#      ftp_chdir(dir) or return false
#    end
#    cmd = "LIST " + filename
#    retrlines(cmd) do |line|
#      if line == 'filename'
#        return true
#      end
#    end
#    return false
#  end



  def is_error?
    return @error
  end


  def err (message)
    real_echo("!!! " + message, false)
    @error = true
    return false
  end


  def echo (message, formatted = true, newline = true)
    if @verbose
      real_echo(message, formatted, newline)
    else
      log_msg(message, newline)
    end
  end


  def real_echo (message, formatted = true, newline = true)
    msg = (formatted ? '> ' :'') + message
    print msg + (newline ? "\n" : "")
    log_msg(msg, newline)
  end


  def log_msg (msg, newline = true)
    if @output_log
      @output_log.syswrite(msg + (newline ? "\n" : ""))
    end
  end


  def print_result_message
    nochange = ''
    if @created_files + @created_dirs > 0
      real_echo "Bylo synchronizováno #{@created_files} souborů a vytvořeno #{@created_dirs} složek."
    else
      nochange = ' Nebyly provedeny žádné změny.'
    end
    if @error
      err 'Synchronizace nebyla provedena!'
    else
      real_echo 'Synchronizace proběhla úspěšně.' + nochange
    end
  end
end



synaum = Synaum.new()
if !synaum.is_error?
  synaum.synchronize
end
synaum.print_result_message