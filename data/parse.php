<?php

$file = fopen($argv[1],"r");
$finalString = "";
while(!feof($file)){
	$line = fgets($file);
	$time = end(explode("] ", $line));
	$finalString = $finalString . ", " . trim($time);
}
print($finalString);
fclose($file);


?>
