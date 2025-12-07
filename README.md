# SnippetSearcher-Infrastructure

---

## Login to ghcr
### Log in:
<pre>
echo "&lt;TOKEN&gt;" | docker login ghcr.io -u &lt;USER&gt; --password-stdin
</pre>

The token must have the `read:packages` property.

### Test:
<pre>
docker pull ghcr.io/grupo-14-ingsis/snippetsearcher-accessmanager:latest
</pre>

Should output:
<pre>
latest: Pulling from grupo-14-ingsis/snippetsearcher-accessmanager
878ac3eb251b: Pull complete
015f975f5fed: Pull complete
70d49c5cce9c: Pull complete
5bd36b0c9c64: Pull complete
ef8b2747f33a: Pull complete
Digest: sha256:f23d393b3b5408ab4eaaf317e48ad595b15f024932ca293d18c39640636e3867
Status: Downloaded newer image for ghcr.io/grupo-14-ingsis/snippetsearcher-accessmanager:latest
ghcr.io/grupo-14-ingsis/snippetsearcher-accessmanager:latest
</pre>

---

## Connect to VM via SSH:
<pre>ssh -i &lt;.pem file&gt; azureuser@20.246.106.222</pre>

---

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