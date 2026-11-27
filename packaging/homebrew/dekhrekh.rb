# Homebrew formula: builds from source, so no notarized download is needed.
# Publish it in a tap repo (github.com/Ditou007/homebrew-tap, file Formula/dekhrekh.rb), then:
#   brew install --HEAD ditou007/tap/dekhrekh
class Dekhrekh < Formula
  desc "Always-on-top macOS panel for Claude Code sessions, usage, CI and pull requests"
  homepage "https://github.com/Ditou007/dekhrekh"
  head "https://github.com/Ditou007/dekhrekh.git", branch: "main"
  license "MIT"

  depends_on :macos

  def install
    # Ad-hoc signing: Homebrew's build environment cannot reach the keychain's certificates.
    system({ "DEKHREKH_SIGN_ID" => "-" }, "./build.sh")
    prefix.install "build/Dekhrekh.app"
    bin.install "build/dekhrekh"
  end

  def caveats
    <<~EOS
      Start the panel (and add it to Login Items to keep it running):
        open #{opt_prefix}/Dekhrekh.app
      Connect Claude Code to it:
        dekhrekh setup
    EOS
  end

  test do
    assert_match "config", shell_output("#{bin}/dekhrekh config")
  end
end
