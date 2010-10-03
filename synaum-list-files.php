<?php
require_once('../../system/php/ajax-base.php');

/**
 * Script for generating the Synaum synchronization file.
 * It is intended for spped-up synchronization - passing through the directory tree
 *  is done here, on the server side. It produces the output file "synaum-list.txt",
 *  which can be read by the client (source) side ruby script.
 * The libs files are ignored by default, but they can be handled when the $_GET
 * value "libs" is set.
 * @param $_GET['last_sync'] Last synchronization time and date (used for comparing whether modified)
 * @param $_GET['libs'] If set, modules libraries folders will be listed too.
 */

# create the output file
$outFile = @fopen(ROOT_PATH.'/synaum-list.txt', 'w');
if (!$outFile)
  die('Opening the file "' . ROOT_PATH.'/synaum-list.txt" for writing failed.');

# start with the root
listDirectory('/');
echo '1';


function listDirectory ($path)
{
  global $outFile;
  $fullPath = ROOT_PATH . $path;

  if (is_file($fullPath))
  {
    echo 'Zadaný adresář "'.$fullPath.'" je souborem, takže jej nelze procházet';
    return false;
  }

  $files = array();
  $dirs = array();

  foreach (scandir($fullPath) as $file)
  {
    if ($file == '.' or $file == '..')
      continue;
    $newPath = $fullPath . $file;
    if (is_dir($newPath))
    {
      if (isset($_GET['libs']) or !preg_match('@^'.ROOT_PATH.'/modules/[^/]+/libraries@', $newPath))
        $dirs[] = $path . $file . '/';
      $mtime = 'd';
    }
    else
    {
      $mtime = filemtime($newPath);
      if ($mtime <= $_GET['last_sync'])
        $mtime = '';
    }
    $files[] = $file . '//' . $mtime;
  }
  if (count($files))
    fwrite($outFile, $path . "\t" . join("\t", $files) . "\n");
  unset($files); # saving the memory for recursion...

  foreach ($dirs as $dir)
    listDirectory($dir);
}
?>
