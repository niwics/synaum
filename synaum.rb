#!/usr/bin/ruby
# author Miroslav Kvasnica - niwi (miradrda@volny.cz), niwi.cz, 2010
require 'net/ftp'
require 'net/http'
require "fileutils"

class Synaum

  POSSIBLE_PARAMS = ['a', 'b', 'd', 'f', 'g', 'h', 'l', 'r', 's', 't']
  DATE_FORMAT = "%d/%m/%Y, %H:%M:%S (%A)"
  SYNC_FILENAME = 'synaum-log'
  SYNC_FILES_LIST_NAME = 'synaum-list.txt'
  SYNAUM_FILE = '/modules/system/ajax/synaum-list-files.php'
  SRC_IGNORED_FILES = ['/modules']
  SRC_FTP_IGNORED_FILES = ['/config-local.php']
  DST_IGNORED_FILES = ['synaum-log', 'synaum-list.txt']
  HELP_NAMES = ['help', '-help', '-h', '--help', '--h']

  @error
  @verbose
  @debug
  @interactive
  @remove_missing_sources
  @ignore_libraries

  @website
  @src_dir
  @params

  @mode
  @deep
  @local
  @simulation
  @forced
  @all

  # FTP connection (Net::FTP) connector
  # - also used for bool testing - so it's pre-inited
  #   to the true in parse_params function
  @ftp
  @ftp_servername
  @ftp_dir
  @username
  @password
  @http_servername
  @port
  @local_dir
  @modules
  @excluded_modules
  @src_ignored_files

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
  @removed_files
  @source_missing_info
  @remote_modif_info

  def initialize
    # default values
    @ftp_mode = true
    @ftp_dir = ''
    @local_dir = ''
    @modules = []
    @excluded_modules = []
    @src_ignored_files = SRC_IGNORED_FILES
    @old_remote_modifieds = []
    @new_remote_modifieds = []
    @module_names = []
    @ftp_remote_list = {}
    @verbose = true
    @interactive = true
    @last_date = Time.gm(1970, 1, 1)  # gm for global time
    @created_dirs = @created_files = @removed_files = 0
    @ignore_libraries = true
    parse_params
    if !@error
      @src_dir = get_website_dir(@website, true)
    end
    open_output_log if !@error
    load_settings if !@error
  end



  # parse params
  def parse_params
    param1 = ARGV.shift
    if !param1
      return err 'Nebyl zadán název webu pro synchronizaci.'
    elsif HELP_NAMES.include?param1
      print_help_and_exit
    end
    if param1[0,1] == '-'
      @params = param1
      @website = ARGV.shift
      if !@website
        return err 'Nebyl zadán název webu pro synchronizaci.'
      elsif HELP_NAMES.include?@website
        print_help_and_exit
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
        when 'a' then @all = true
        when 'b' then @ignore_libraries = false
        when 'd' then @debug = true
        when 'e' then @deep = true
        when 'f' then @forced = true
        when 'h' then print_help_and_exit
        when 'l' then @local = true
        when 'n' then @interactive = false
        when 'r' then @remove_missing_sources = true
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

    # ignore local config when local config
    if @ftp
      @src_ignored_files += SRC_FTP_IGNORED_FILES
    end
    
    return true
  end


  def open_output_log
    # create dirs if they don't exist
    this_dir = File.dirname(__FILE__)
    website_dirname = @website.gsub('/', '_')
    now = Time.now().strftime("%Y-%m-%d, %H:%M:%S (%A)")
    cond_mkdir_local(this_dir+'/logs')
    cond_mkdir_local(this_dir+'/logs/'+website_dirname)
    cond_mkdir_local(this_dir+'/logs/'+website_dirname+'/'+@mode)
    @output_log = File.open(this_dir+'/logs/'+website_dirname+'/'+@mode+'/'+now, "w")
  end



  # check for the existency of selected website
  def get_website_dir (website, is_main = false)
    if website.index('/') # - was the website name set with a path?
      src_dir = website
      # check existency of specified path
      if !File.exist?(website)
        return err 'Zadaný adresář pro synchronizaci "'+ src_dir +'" není platný.'
      end
    else
      module_msg = is_main ? '' : ' modulu z'
      # try to select the website from the parent folder
      orig_path = Dir.pwd
      Dir.chdir(File.dirname(__FILE__))
      Dir.chdir('..')
      parent_dir = Dir.pwd
      src_dir = script_based_dir = parent_dir+'/'+website
      Dir.chdir(orig_path)
      if !File.exist?(src_dir)
        # search for all folders which names starts with the given name
        if is_main
          res = search_for_source_dir(website, parent_dir)
          if res
            return res
          end
        end
        # try to load path from the config file
        if @config_dir != nil # is cached in @config_dir yet?
          src_dir = @config_dir+'/'+website
        elsif !File.exist?(File.dirname(__FILE__)+"/config")
          @config_dir = false # for future use
          err 'Nepodařilo se najít složku "'+ src_dir +'" pro provedení synchronizace'+ module_msg +' webu "'+ website +'", ani nebyl nalezen soubor "'+ File.dirname(__FILE__) +'/config", odkud by bylo možné načíst cestu k této složce.'
          return err "Možné zadání cesty ke složce:\n - jako parametr skriptu (např. /work/my-website)\n - v parametru jen název složky např. my-website)\n     - a tato složka musí být umístěna vedle složky se tímto Synaum skriptem\n     - NEBO cesta musí být zadána v souboru config umístěném vedl tohoto Synaum skriptu."
        else  # load value and cache it into the variable @config_dir
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
            # search for all folders which names starts with the given name
            if is_main
              res = search_for_source_dir(website, @config_dir)
              if res
                return res
              end
            end
            dir_string = (script_based_dir == src_dir ? '' : script_based_dir + ' ani ') + src_dir
            return err 'Nebyla nalezena složka "'+ dir_string +'" pro provedení synchronizace'+ module_msg +' webu "' + website + '".'
          end
        end
      end
    end
    return src_dir
  end


  def search_for_source_dir (website, parent_dir)
    if !File.exist?(parent_dir)
      return false
    end
    possible_dirs = []
    Dir.entries(parent_dir).each do |filename|
      if filename =~ /^#{website}/ and File.directory?(parent_dir+'/'+filename)\
          and File.exist?(parent_dir+'/'+filename+"/synaum")
        possible_dirs << filename
      end
    end
    if possible_dirs.count == 1
      @website = possible_dirs[0]
      return parent_dir + '/' + possible_dirs[0]
    end
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
          if name == 'ftp' or name == 'local-dir'
            return err 'Nebyla zadána hodnota u parametru "'+ name +'" v konfiguračním souboru "'+ @src_dir+'/synaum' +'".'
          else  # ignore other empty variables
            next
          end
        end
        case name
          when 'ftp' then @ftp_servername = value
          when 'ftp-dir' then @ftp_dir = value[0..1]=='/' ? value : '/'+value
          when 'username' then @username = value
          when 'password' then @password = value
          when 'http-servername' then @http_servername = value
          when 'port' then @port = value
          when 'local-dir' then @local_dir = value
          when 'modules' then @modules = value.split(' ')
          when 'excluded-modules' then @excluded_modules = value.split(' ')
          when 'ignored-files' then @src_ignored_files += value.split(' ')
        else
          return err 'Neznámý parametr "'+ name +'" v konfiguračním souboru "'+ @src_dir+'/synaum' +'".'
        end
      end
    end

    # check params for FTP
    if !@local and !@deep
      if !@ftp_servername
        return err 'V konfiguračním souboru "'+ @src_dir+'/synaum' +'" nebyl zadán FTP server pro synchronizaci. Pokud chcete pracovat pouze s lokálními soubory, použijte přepínač -d nebo -l (viz nápověda - "synaum help")'
      elsif !@username
        return err 'Nebylo zadáno uživatelské jméno pro připojení k FTP serveru.'
      end
      if !@http_servername
        @http_servername = @ftp_servername
      end
      if @port == '443'
        begin
          require 'net/https'
        rescue LoadError
          return err "Nebyla nalezena knihovna \"net/https\", která je potřebná k HTTPS připojení k serveru (v konfiguračním souboru \"#{@src_dir}/synaum\" byl totiž zadán HTTPS port #{@port}."
        end
      end
    elsif @local_dir == ''
      return err 'V konfiguračním souboru "'+ @src_dir+'/synaum' +'" nebyla zadána složka pro lokální synchronizaci (local-dir).'
    end

    # add initial slashes
    @src_ignored_files = @src_ignored_files.map {|item|  (item[0..0] == '/' ? item : '/'+item)}

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
    if @ftp
      load_ftp_list or return false
    end
    # do synchronization
    sync_modules
    if !@error and File.exist?(@src_dir)
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
    
    if @ftp_dir != '' and !dst_file_exist?(@ftp_dir, false)
      return err "Na serveru nebyla nalezena zadaná kořenová složka \"#{@ftp_dir}\". Zkontrolujte existenci této složky a její oprávnění zápisu. Cestu k ní je možné upravit v konfiguračním souboru \"#{@src_dir}/synaum\"."
    end
    return true
  end


  def check_dst_dir
    # check existency of local folder
    if !@dst_dir
      return err 'Nebyla zadána cesta pro lokální režim (= hodnota "path" v konfiguračním souboru "'+ @src_dir +'/synaum")'
    end
    separ = @local_dir.rindex(File::SEPARATOR) - 1
    local_parent = @local_dir[0..separ]
    if !File.exist?(local_parent)
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
      rems_allowed = false
      sync_file = File.new((@ftp ? '/tmp' : @dst_dir) + '/' + SYNC_FILENAME, "r")
      while line = sync_file.gets
        line.chomp!
        if line[0,1] != '#' and line != ''
          name, value = line.split(' ', 2)
          if !value and !rems_allowed
            return err "Nebyla zadána hodnota u proměnné \"#{name}\" v konfiguračním souboru \"#{@dst_dir}/#{SYNC_FILENAME}\"."
          end
          case name
            when 'last-synchronized' then
              arr = value.split(', ')
              begin
                vals = arr[0].split('/') + arr[1].split(':')
                @last_date = Time.mktime(vals[2], vals[1], vals[0], vals[3], vals[4], vals[5])
              rescue
                echo "Nepodařilo se načíst datum poslední synchronizace (hodnota \"#{value}\") z konfiguračního souboru \"#{@dst_dir}/#{SYNC_FILENAME}\"."
              end
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


  def load_ftp_list
    # call remote ajax PHP script and load directories list
    ajax_name = SYNAUM_FILE + '?last_sync='+@last_date.to_i.to_s
    if !@ignore_libraries
      ajax_name += '&libs=true'
    end
    if @debug
      echo "Generuji vzdálený soubor pomocí PHP skriptu \"#{ajax_name}\"."
    end
    @port_string = @port == '443' ? 'https' :'http'
    begin
      http = Net::HTTP.new(@http_servername, @port)
    rescue
      return err "Chyba při vytváření HTTP spojení se serverem #{@port_string}://#{@http_servername}. Zkontrolujte adresu serveru (automaticky je shodná s FTP adresou, ale můžete ji také upravit v konfiguračním souboru \"#{@src_dir}/synaum\"."
    end
    if @port == '443'
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    http.start
    if !http.started?
      return err "Nepodařilo se vytvořit HTTP připojení se serverem \"#{@port_string}://#{@http_servername}\". Zkontrolujte adresu serveru (automaticky je shodná s FTP adresou, ale můžete ji také upravit v konfiguračním souboru \"#{@src_dir}/synaum\"."
    end
    begin
      res = http.get(ajax_name)
    rescue
      return err "Nepodařilo se načíst AJAXový PHP skript \"#{@port_string}://#{@http_servername}#{ajax_name}\"."
    end
    if res.code[0..0] != '2'
      if dst_file_exist?(SYNAUM_FILE)
        err "Chyba při volání AJAXového Synaum skriptu \"#{@port_string}://#{@http_servername}#{ajax_name}\"."
        echo "Skript na FTP existuje, ale jeho volání přes HTTP selhalo."
        echo "HTTP odpověď: " + res.code + ": " + res.message
        exit
      end
      echo 'Chcete provést inicializaci nového webu? [Y/n]'
      answer = gets
      answer = answer.strip.downcase
      if answer == 'y' or answer == ''
        @ignore_libraries = false
        return true
      else
        err "Nebyla provedena inicializace a ani synchronizace.\nAJAXový Synaum skript \"#{@port_string}://#{@http_servername}#{ajax_name}\" nebyl nalezen."
        exit
      end
    end
    if res.body != '1'
      return err "Neúspěšné volání AJAXového PHP skriptu - skript \"#{@port_string}://#{@http_servername}#{ajax_name}\" nevrátil hodnotu \"1\"."
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
    sync('/modules/', @src_dir) if File.exist?(@src_dir + '/modules')
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
      surplus_files = remote_files.keys - files
      if dir == '/modules/'
        surplus_files -= @module_names
      elsif dir == '/'
        system_dir = get_website_dir('gorazd-system')
        surplus_files -= Dir.entries(system_dir+'/www')
        surplus_files -= DST_IGNORED_FILES
      end
      surplus_files.each do |f|
        handle_source_missing(dir+f, src_root)
      end
    end
    
    files.each do |file|
      if file != '.' and file != '..' and\
          file !~ /~$/ and (!@ignore_libraries or file != 'libraries' or dir !~ /.*\/modules\/[^\/]+\/$/) and\
          !@src_ignored_files.include?(dir+file)\
          and (!allowed_files or allowed_files.include?(file))
        remote_exists = remote_files.key?(file)
        if @debug
          echo '...kontrola souboru "' + src_root + dir + file+'"...'
        end
        if dir == '/' and DST_IGNORED_FILES.include?(file)
          next
        end
        if @local
          if !remote_exists
            file_move(src_root+dir+file, @dst_dir+dir+file)
          end
        elsif File.directory?(src_root+dir+file)
          if !remote_exists and !@simulation
            mkdir(@dst_dir+dir+file)
          end
          sync(dir + file + '/', src_root)
        else  # handle remote file...
          copy = false
          if @simulation
            copy = false
          elsif remote_exists
            if @all
              copy = true
            else
              # src file modification time
              copy = File.stat(src_root+dir+file).mtime > @last_date
            end
            if dst_modified?(dir+file, remote_files[file])  # dst file modification time
              copy = handle_remote_modified(dir + file, src_root)
            end
          else  # copy non-existing
            copy = true
          end
          if copy #(!remote_exists or (src_modified and !dst_modified) or (dst_modified and @forced))
            file_move(src_root+dir+file, @dst_dir+dir+file)
          end
        end
      end
    end
  end


  def handle_source_missing (path, src_root)
    if @ftp and @interactive
      println "\n    SOURCE_MISSING: " + path + '. Vyberte akci:'
      print '    Use/load remote (u), Remove remote (r), Skip (s, výchozí), Skip All (a):'
      answer = gets
      print "\n"
      answer = answer.strip.downcase
      if answer == 'a'
        @interactive = false
      elsif answer == 'u'
        echo 'SOURCE_MISSING - stahuji: '+path
        ftp_download(@dst_dir+path, src_root+path)
        return
      elsif answer == 'r'
        remove = true
      end
    end

    if @remove_missing_sources or remove
      echo 'SOURCE_MISSING - odstraňuji: '+path
      ftp_remove @dst_dir + path
      return
    end

    if @verbose
      echo 'SOURCE_MISSING: '+path
      @source_missing_info = true
    end
  end

  def handle_remote_modified (path, src_root)
    overwrite_string = 'REMOTE-MODIFIED - přepíšu vzdálený lokálním: '+path
    if @forced
      echo overwrite_string
      return true # true means: COPY IN CALLER FUNCTION
    end

    if @ftp and @interactive
      println "\n    REMOTE-MODIFIED: " + path + '. Vyberte akci:'
      while true  # loop for changing options (caused by diff)
        print '    Use/load remote (u), Overwrite by local (l), Diff (d), Skip (s, výchozí), Skip All (a):'
        answer = gets
        print "\n"
        answer = answer.strip.downcase
        if answer == 'a'
          @interactive = false
          break
        elsif answer == 'u'
          echo 'REMOTE-MODIFIED - stahuji vzdálený: '+path
          ftp_download(@dst_dir+path, src_root+path)
          return false  # false means: NO COPY IN CALLER FUNCTION
        elsif answer == 'l'
          echo overwrite_string
          return true # true means: COPY IN CALLER FUNCTION
        elsif answer == 'd'
          tmp_path = '/tmp/remote_synaum_diff'
          @ftp.getbinaryfile(@dst_dir+path, tmp_path)
          res = system('kompare '+ src_root+path +' '+ tmp_path)
          if !res
            println 'Nebyl nalezen program Kompare pro porovnání souborů!'
          end
          File.delete(tmp_path)
        else  # skip - end of loop
          break
        end
      end
    end

    if @ftp
      @new_remote_modifieds << path
    end
    
    if @verbose
      echo 'REMOTE-MODIFIED: '+path
      @remote_modif_info = true
    end
    return false # false means: NO COPY IN CALLER FUNCTION
  end


  def list_remote_files (path)
    list = {}
    if @ftp
      begin
        if !@ftp_remote_list[path]
          return list
        end
        # split appropriate fiels string
        files = @ftp_remote_list[path].split("\t")
        files.each do |line|
          file, date = line.split("//")
          list[file] = date
        end
      rescue
        err "Chyba při procházení stromem na serveru - \"#{path}\" není složka!"
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


  def dst_modified? (file, remote_flag = nil)
    if @old_remote_modifieds.include?(file)
      return true
    end
    if @local or @deep
      return File.stat(@dst_dir+file).mtime > @last_date
    else
      return remote_flag
    end
    return false
  end


  def file_move (src, dst, control_file = false)
    if !control_file or @debug
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
#  end@ftp.list(@dst_dir + dir + f)


  def ftp_remove path
    return ftp_action(true, path)
  end


  def ftp_download (path, local_path)
    return ftp_action(false, path, local_path)
  end


  def ftp_action (is_remove, path, local_path = nil)
    is_file = false
    begin
      @ftp.chdir(path)
    rescue
      is_file = true
    end
    if is_file
      begin
        if is_remove
          @ftp.delete(path)
        else
          echo 'Stahuji SOURCE-MISSING soubor: ' + path
          @ftp.getbinaryfile(path, local_path)
        end
      rescue
        return err 'Chyba při '+ (is_remove ? 'odstraňování':'stahování') +' vzdáleného souboru "' + path + local_path +'".'
      end
    else
      ftp_action_loop(is_remove, path, local_path)
    end
    is_remove ? (@removed_files += 1) : (@created_files += 1)
  end

  
  def ftp_action_loop (is_remove, dirname, local_path)
    if !is_remove
      begin
        Dir.mkdir(local_path)
      rescue
        return err 'Chyba při vytváření lokální složky "' + local_path + '".'
      end
    end
    @ftp.nlst(dirname).each do |f|
      ftp_action(is_remove, f, local_path+'/'+File.basename(f))
    end
    if is_remove
      begin
        @ftp.rmdir(dirname)
      rescue
        return err 'Chyba při odstraňování vzdálené složky "' + dirname + '".'
      end
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
    if @source_missing_info
      echo 'Některé soubory na serveru nemají odpovídající zdroj (SOURCE-MISSING). Pokud je chcete ze serveru smazat, použijte přepínač "-r".'
    end
    if @remote_modif_info
      echo 'Některé soubory byly na serveru změněny (REMOTE-MODIFIED), avšak zůstaly na serveru ve své původní podobě. Pokud je chcete přepsat soubory ze zdrojového počítače, použijte přepínač "-f".'
    end
    if @created_files + @created_dirs + @removed_files > 0
      if @created_files + @created_dirs > 0
        real_echo "Bylo synchronizováno #{@created_files} souborů a vytvořeno #{@created_dirs} složek."
      end
      if @removed_files > 0
        real_echo "Bylo smazáno #{@removed_files} SOURCE-MISSING souborů."
      end
    else
      nochange = ' Nebyly provedeny žádné změny.'
    end
    if @error
      err 'Synchronizace nebyla provedena!'
    else
      real_echo 'Synchronizace proběhla úspěšně.' + nochange
    end
  end


  def print_help_and_exit
    puts <<EOT
----------------------------
 Nápověda k programu Synaum
----------------------------
Synaum je synchronizační skript pro systém Gorazd, podrobnosti najdete na webu http://gorazd.niwi.cz.
Slouží k aktualizaci webu oproti zdrojové složce na lokálním počítači.
> Spuštění programu:
\tsynaum.rb nazev-webu [-#{POSSIBLE_PARAMS.join()}]
nebo s obrácenými parametry:
\tsynaum.rb [-#{POSSIBLE_PARAMS.join()}] nazev-webu

Povolené parametry programu:
\t-a\tsynchronize All\n\t\t-vynuti aktualizaci vsech vzdalenych souboru
\t-b\tsynchronize liBraries\n\t\t- zahrne do synchronizace také knihovny (libraries)
\t-d\tDebug\n\t\t- vypisuje ladicí hlášky
\t-e\tdEep mode\n\t\t- lokální synchronizace s vytvořením fyzické kopie souborů
\t-f\tForce REMOTE-MODIFIED\n\t\t- přepíše cílové soubory i pokud jsou v cíli modifikovány
\t-h\tHelp\n\t\t- zobrazí tuto nápovědu k programu
\t-l\tLocal mode\n\t\t- lokální synchronizace s využitím symlinků z cíle do zdroje
\t-n\tNon-interactive\n\t\t- neinteraktivní režim (vhodný pro práci se SOURCE_MISSING a REMOTE_MODIFIED)
\t-r\tRemove SOURCE-MISSING\n\t\t- odstraní ze serveru všechny soubory s chybějícím zdrojem (SOURCE-MISSING)
\t-s\tSimulation\n\t\t- provede jen informativní výpis a kontrolu, ale nekopíruje soubory
\t-t\tsilenT\n\t\t- program nebude vypisovat informace o prováděné činnosti

Zdrojová složka webu může být zadána jako "nazev-webu" - v takovém případě se skript pokusí najít tento web v rodičovské složce skriptu a v případě neúspěchu pak ve složce zadané v konfiguračním souboru "config" ve složce skriptu.
 K zadání zdrojové složky stačí zadat jen počáteční unikátní písmena a skript se pokusí složu najít sám.
 Také může být zadána i s absolutní cestou ke složce - např. "/devel/my-web".
EOT
    exit
  end

  def println msg
    print msg + "\n"
  end
end



synaum = Synaum.new()
if !synaum.is_error?
  synaum.synchronize
end
synaum.print_result_message