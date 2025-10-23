# SnippetSearcher-Infrastructure

## Connect via SSH:
<pre>ssh -i [.pem file] azureuser@20.246.106.222</pre>

## Create GitHub Actions Runner:

### Download runner
<pre>
# Create a folder under the drive root
$ mkdir actions-runner; cd actions-runner

# Download the latest runner package
$ Invoke-WebRequest -Uri https://github.com/actions/runner/releases/download/v2.329.0/actions-runner-win-x64-2.329.0.zip -OutFile actions-runner-win-x64-2.329.0.zip

# Optional: Validate the hash
$ if((Get-FileHash -Path actions-runner-win-x64-2.329.0.zip -Algorithm SHA256).Hash.ToUpper() -ne 'f60be5ddf373c52fd735388c3478536afd12bfd36d1d0777c6b855b758e70f25'.ToUpper()){ throw 'Computed checksum did not match' }

# Extract the installer
$ Add-Type -AssemblyName System.IO.Compression.FileSystem ; [System.IO.Compression.ZipFile]::ExtractToDirectory("$PWD/actions-runner-win-x64-2.329.0.zip", "$PWD")
</pre>

### Configure runner
<pre>
# Create the runner and start the configuration experience
$ ./config.cmd --url https://github.com/Grupo-14-INGSIS/SnippetSearcher-Infrastructure --token [YOUR_TOKEN_HERE]

# Run it!
$ ./run.cmd
</pre>

### Start runner

Execute every time the VM starts
<pre>
$ ./run.cmd
</pre>
Once the VM stops, the runner is deactivated