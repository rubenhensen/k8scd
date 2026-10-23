// dqlite-vacuum prints page statistics of a dqlite database and, with
// -vacuum, runs VACUUM on it.
//
// The dqlite shell that ships with microk8s wraps every statement in a
// transaction, and SQLite refuses to VACUUM inside one. This sends VACUUM as
// a plain statement through the go-dqlite driver instead. dqlite supports it
// from v1.18.2 (canonical/dqlite#734).
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/canonical/go-dqlite/v3/client"
	"github.com/canonical/go-dqlite/v3/driver"
	"gopkg.in/yaml.v2"
)

type stats struct {
	pageSize, pages, free, rows int64
}

func (s stats) String() string {
	mb := func(pages int64) float64 { return float64(pages*s.pageSize) / 1e6 }
	return fmt.Sprintf("%d pages (%.0f MB), %d free (%.0f MB), %d kine rows",
		s.pages, mb(s.pages), s.free, mb(s.free), s.rows)
}

func main() {
	dir := flag.String("dir", "/var/snap/microk8s/current/var/kubernetes/backend", "dqlite backend directory with info.yaml, cluster.crt and cluster.key")
	name := flag.String("db", "k8s", "database name")
	vacuum := flag.Bool("vacuum", false, "run VACUUM; without it only print statistics")
	timeout := flag.Duration("timeout", 10*time.Minute, "timeout for VACUUM")
	flag.Parse()
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	var info struct {
		Address string `yaml:"Address"`
	}
	data, err := os.ReadFile(filepath.Join(*dir, "info.yaml"))
	if err != nil {
		log.Fatal(err)
	}
	if err := yaml.Unmarshal(data, &info); err != nil || info.Address == "" {
		log.Fatalf("no address in info.yaml: %v", err)
	}

	dial, err := tlsDial(filepath.Join(*dir, "cluster.crt"), filepath.Join(*dir, "cluster.key"))
	if err != nil {
		log.Fatal(err)
	}
	store := client.NewInmemNodeStore()
	if err := store.Set(context.Background(), []client.NodeInfo{{Address: info.Address}}); err != nil {
		log.Fatal(err)
	}
	drv, err := driver.New(store, driver.WithDialFunc(dial), driver.WithConnectionTimeout(10*time.Second))
	if err != nil {
		log.Fatal(err)
	}
	sql.Register("dqlite", drv)
	db, err := sql.Open("dqlite", *name)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	// One connection, so VACUUM never runs next to a statement of our own.
	db.SetMaxOpenConns(1)

	before, err := readStats(db)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("%s: %s", info.Address, before)
	if !*vacuum {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	start := time.Now()
	log.Print("VACUUM started")
	if _, err := db.ExecContext(ctx, "VACUUM"); err != nil {
		log.Fatalf("VACUUM failed after %s: %v", time.Since(start).Round(time.Millisecond), err)
	}
	log.Printf("VACUUM done in %s", time.Since(start).Round(time.Millisecond))

	after, err := readStats(db)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("%s: %s", info.Address, after)
}

func readStats(db *sql.DB) (stats, error) {
	var s stats
	for _, q := range []struct {
		sql string
		dst *int64
	}{
		{"PRAGMA page_size", &s.pageSize},
		{"PRAGMA page_count", &s.pages},
		{"PRAGMA freelist_count", &s.free},
		{"SELECT COUNT(*) FROM kine", &s.rows},
	} {
		if err := db.QueryRow(q.sql).Scan(q.dst); err != nil {
			return s, fmt.Errorf("%s: %w", q.sql, err)
		}
	}
	return s, nil
}

// tlsDial mirrors go-dqlite's app.SimpleDialTLSConfig, which can't be
// imported without cgo.
func tlsDial(crt, key string) (driver.DialFunc, error) {
	cert, err := tls.LoadX509KeyPair(crt, key)
	if err != nil {
		return nil, err
	}
	pem, err := os.ReadFile(crt)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("bad certificate %s", crt)
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return nil, err
	}
	if len(leaf.DNSNames) == 0 {
		return nil, fmt.Errorf("certificate %s has no DNS name", crt)
	}
	config := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		RootCAs:            pool,
		Certificates:       []tls.Certificate{cert},
		ClientSessionCache: tls.NewLRUClientSessionCache(0),
		ServerName:         leaf.DNSNames[0],
	}
	return client.DialFuncWithTLS(client.DefaultDialFunc, config), nil
}
