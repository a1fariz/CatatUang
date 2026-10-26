package pgtools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type Manifest struct {
	Version   int       `json:"version"`
	Format    string    `json:"format"`
	SHA256    string    `json:"sha256"`
	CreatedAt time.Time `json:"created_at"`
}

func Environment(raw, database string) ([]string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.User == nil || u.Hostname() == "" || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		return nil, errors.New("invalid PostgreSQL connection configuration")
	}
	env := []string{}
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if !strings.HasPrefix(strings.ToUpper(key), "PG") {
			env = append(env, item)
		}
	}
	password, _ := u.User.Password()
	port := u.Port()
	if port == "" {
		port = "5432"
	}
	if database == "" {
		database = strings.TrimPrefix(u.Path, "/")
	}
	env = append(env, "PGHOST="+u.Hostname(), "PGPORT="+port, "PGUSER="+u.User.Username(), "PGPASSWORD="+password, "PGDATABASE="+database, "PGCONNECT_TIMEOUT=10", "PGAPPNAME=catatuang-backup")
	for key, variable := range map[string]string{"sslmode": "PGSSLMODE", "sslrootcert": "PGSSLROOTCERT", "sslcert": "PGSSLCERT", "sslkey": "PGSSLKEY", "channel_binding": "PGCHANNELBINDING"} {
		if value := u.Query().Get(key); value != "" {
			env = append(env, variable+"="+value)
		}
	}
	return env, nil
}
func Command(ctx context.Context, bin, name string, env []string, args ...string) *exec.Cmd {
	if bin != "" {
		name = filepath.Join(bin, name)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	return cmd
}
func Checksum(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err = io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
func Backup(ctx context.Context, raw, bin, destination string) (Manifest, error) {
	var manifest Manifest
	env, err := Environment(raw, "")
	if err != nil {
		return manifest, err
	}
	if _, err = os.Stat(destination + ".json"); !os.IsNotExist(err) {
		return manifest, errors.New("backup manifest already exists or is inaccessible")
	}
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return manifest, errors.New("cannot create new backup file")
	}
	complete := false
	defer func() {
		_ = file.Close()
		if !complete {
			_ = os.Remove(destination)
		}
	}()
	cmd := Command(ctx, bin, "pg_dump", env, "--format=custom", "--no-owner", "--no-privileges")
	cmd.Stdout = file
	cmd.Stderr = io.Discard
	if err = cmd.Run(); err != nil {
		return manifest, errors.New("pg_dump failed; incomplete file removed")
	}
	if err = file.Sync(); err != nil {
		return manifest, errors.New("backup flush failed")
	}
	if err = file.Close(); err != nil {
		return manifest, errors.New("backup close failed")
	}
	checksum, err := Checksum(destination)
	if err != nil {
		return manifest, errors.New("backup checksum failed")
	}
	manifest = Manifest{Version: 1, Format: "pg_dump-custom", SHA256: checksum, CreatedAt: time.Now().UTC()}
	output, err := os.OpenFile(destination+".json", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return manifest, errors.New("cannot create backup manifest")
	}
	err = json.NewEncoder(output).Encode(manifest)
	if err == nil {
		err = output.Sync()
	}
	closeErr := output.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(destination + ".json")
		return manifest, errors.New("manifest persistence failed")
	}
	complete = true
	return manifest, nil
}
func Verify(path string) error {
	file, err := os.Open(path + ".json")
	if err != nil {
		return errors.New("backup manifest missing")
	}
	defer file.Close()
	var manifest Manifest
	decoder := json.NewDecoder(io.LimitReader(file, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&manifest) != nil || manifest.Version != 1 || manifest.Format != "pg_dump-custom" || len(manifest.SHA256) != 64 {
		return errors.New("invalid backup manifest")
	}
	hash, err := Checksum(path)
	if err != nil || hash != manifest.SHA256 {
		return errors.New("backup checksum mismatch")
	}
	return nil
}
